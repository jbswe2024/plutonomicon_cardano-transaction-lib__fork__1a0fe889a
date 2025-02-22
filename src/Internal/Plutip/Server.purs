module Ctl.Internal.Plutip.Server
  ( checkPlutipServer
  , execDistribution
  , runPlutipContract
  , runPlutipTestPlan
  , startOgmios
  , startKupo
  , startPlutipCluster
  , startPlutipServer
  , stopChildProcessWithPort
  , stopPlutipCluster
  , testPlutipContracts
  , withPlutipContractEnv
  , makeNaiveClusterContractEnv
  , makeClusterContractEnv
  , mkLogging
  , checkPortsAreFree
  ) where

import Contract.Prelude

import Aeson (decodeAeson, encodeAeson, parseJsonStringToAeson, stringifyAeson)
import Affjax (defaultRequest) as Affjax
import Affjax.RequestBody as RequestBody
import Affjax.RequestHeader as Header
import Affjax.ResponseFormat as Affjax.ResponseFormat
import Cardano.Types (NetworkId(MainnetId))
import Cardano.Types.BigNum as BigNum
import Cardano.Types.PrivateKey (PrivateKey(PrivateKey))
import Contract.Chain (waitNSlots)
import Contract.Config (Hooks, defaultSynchronizationParams, defaultTimeParams)
import Contract.Monad (Contract, ContractEnv, liftContractM, runContractInEnv)
import Control.Monad.Error.Class (throwError)
import Control.Monad.State (State, execState, modify_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Writer (censor, execWriterT, tell)
import Ctl.Internal.Affjax (request) as Affjax
import Ctl.Internal.Contract.Monad
  ( buildBackend
  , getLedgerConstants
  , mkQueryHandle
  , stopContractEnv
  )
import Ctl.Internal.Contract.QueryBackend (mkCtlBackendParams)
import Ctl.Internal.Helpers ((<</>>))
import Ctl.Internal.Logging (Logger, mkLogger, setupLogs)
import Ctl.Internal.Plutip.PortCheck (isPortAvailable)
import Ctl.Internal.Plutip.Spawn
  ( ManagedProcess
  , NewOutputAction(Success, NoOp)
  , _rmdirSync
  , spawn
  , stop
  )
import Ctl.Internal.Plutip.Types
  ( ClusterStartupParameters
  , ClusterStartupRequest(ClusterStartupRequest)
  , PlutipConfig
  , PrivateKeyResponse(PrivateKeyResponse)
  , StartClusterResponse(ClusterStartupSuccess, ClusterStartupFailure)
  , StopClusterRequest(StopClusterRequest)
  , StopClusterResponse
  )
import Ctl.Internal.Plutip.Utils
  ( addCleanup
  , after
  , runCleanup
  , tmpdir
  , whenError
  )
import Ctl.Internal.QueryM.UniqueId (uniqueId)
import Ctl.Internal.ServerConfig (ServerConfig)
import Ctl.Internal.Service.Error
  ( ClientError(ClientDecodeJsonError, ClientHttpError)
  , pprintClientError
  )
import Ctl.Internal.Test.ContractTest
  ( ContractTest(ContractTest)
  , ContractTestPlan(ContractTestPlan)
  , ContractTestPlanHandler
  )
import Ctl.Internal.Test.UtxoDistribution
  ( class UtxoDistribution
  , InitialUTxODistribution
  , InitialUTxOs
  , decodeWallets
  , encodeDistribution
  , keyWallets
  , transferFundsFromEnterpriseToBase
  )
import Ctl.Internal.Types.UsedTxOuts (newUsedTxOuts)
import Ctl.Internal.Wallet.Key (PrivatePaymentKey(PrivatePaymentKey))
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Either (Either(Left, Right), either)
import Data.Foldable (fold)
import Data.HTTP.Method as Method
import Data.Log.Level (LogLevel)
import Data.Log.Message (Message)
import Data.Maybe (Maybe(Nothing, Just), fromMaybe, maybe)
import Data.Newtype (over, unwrap, wrap)
import Data.Set as Set
import Data.String.CodeUnits (indexOf) as String
import Data.String.Pattern (Pattern(Pattern))
import Data.Traversable (foldMap, for, for_, traverse_)
import Data.Tuple (fst, snd)
import Data.Tuple.Nested (type (/\), (/\))
import Data.UInt (UInt)
import Data.UInt as UInt
import Effect.Aff (Aff, Milliseconds(Milliseconds), try)
import Effect.Aff (bracket) as Aff
import Effect.Aff.Class (liftAff)
import Effect.Aff.Retry
  ( RetryPolicy
  , constantDelay
  , limitRetriesByCumulativeDelay
  , recovering
  )
import Effect.Class (liftEffect)
import Effect.Exception (error, message, throw)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Mote (bracket) as Mote
import Mote.Description (Description(Group, Test))
import Mote.Monad (MoteT(MoteT), mapTest)
import Mote.TestPlanM (TestPlanM)
import Node.ChildProcess (defaultSpawnOptions)
import Node.FS.Sync (exists, mkdir) as FSSync
import Node.Path (FilePath)
import Partial.Unsafe (unsafePartial)
import Safe.Coerce (coerce)
import Type.Prelude (Proxy(Proxy))

-- | Run a single `Contract` in Plutip environment.
runPlutipContract
  :: forall (distr :: Type) (wallets :: Type) (a :: Type)
   . UtxoDistribution distr wallets
  => PlutipConfig
  -> distr
  -> (wallets -> Contract a)
  -> Aff a
runPlutipContract cfg distr cont = withPlutipContractEnv cfg distr
  \env wallets ->
    runContractInEnv env (cont wallets)

-- | Provide a `ContractEnv` connected to Plutip.
-- | can be used to run multiple `Contract`s using `runContractInEnv`.
withPlutipContractEnv
  :: forall (distr :: Type) (wallets :: Type) (a :: Type)
   . UtxoDistribution distr wallets
  => PlutipConfig
  -> distr
  -> (ContractEnv -> wallets -> Aff a)
  -> Aff a
withPlutipContractEnv plutipCfg distr cont = do
  cleanupRef <- liftEffect $ Ref.new mempty
  Aff.bracket
    (try $ startPlutipContractEnv plutipCfg distr cleanupRef)
    (const $ runCleanup cleanupRef)
    $ liftEither
    >=> \{ env, wallets, printLogs } ->
      whenError printLogs (cont env wallets)

-- | Run several `Contract`s in tests in a (single) Plutip environment (plutip-server and cluster, kupo, etc.).
-- | NOTE: This uses `MoteT`s bracketing, and thus has the same caveats.
-- |       Namely, brackets are run for each of the top-level groups and tests
-- |       inside the bracket.
-- |       If you wish to only set up Plutip once, ensure all tests that are passed
-- |       to `testPlutipContracts` are wrapped in a single group.
-- | https://github.com/Plutonomicon/cardano-transaction-lib/blob/develop/doc/plutip-testing.md#testing-with-mote
testPlutipContracts
  :: PlutipConfig
  -> TestPlanM ContractTest Unit
  -> TestPlanM (Aff Unit) Unit
testPlutipContracts plutipCfg tp = do
  plutipTestPlan <- lift $ execDistribution tp
  runPlutipTestPlan plutipCfg plutipTestPlan

-- | Run a `ContractTestPlan` in a (single) Plutip environment.
-- | Supports wallet reuse - see docs on sharing wallet state between
-- | wallets in `doc/plutip-testing.md`.
runPlutipTestPlan
  :: PlutipConfig
  -> ContractTestPlan
  -> TestPlanM (Aff Unit) Unit
runPlutipTestPlan plutipCfg (ContractTestPlan runContractTestPlan) = do
  -- Modify tests to pluck out parts of a single combined distribution
  runContractTestPlan \distr tests -> do
    cleanupRef <- liftEffect $ Ref.new mempty
    -- Sets a single Mote bracket at the top level, it will be run for all
    -- immediate tests and groups
    bracket (startPlutipContractEnv plutipCfg distr cleanupRef)
      (runCleanup cleanupRef)
      $ flip mapTest tests \test { env, wallets, printLogs, clearLogs } -> do
          whenError printLogs (runContractInEnv env (test wallets))
          clearLogs
  where
  -- `MoteT`'s bracket doesn't support supplying the constructed resource into
  -- the main action, so we use a `Ref` to store and read the result.
  bracket
    :: forall (a :: Type) (b :: Type)
     . Aff a
    -> Aff Unit
    -> TestPlanM (a -> Aff b) Unit
    -> TestPlanM (Aff b) Unit
  bracket before' after' act = do
    resultRef <- liftEffect $ Ref.new (Left $ error "Plutip not initialized")
    let
      before = do
        res <- try $ before'
        liftEffect $ Ref.write res resultRef
        pure res
      after = const $ after'
    Mote.bracket { before, after } $ flip mapTest act \t -> do
      result <- liftEffect $ Ref.read resultRef >>= liftEither
      t result

-- | Lifts the UTxO distributions of each test out of Mote, into a combined
-- | distribution. Adapts the tests to pick their distribution out of the
-- | combined distribution.
-- | NOTE: Skipped tests still have their distribution generated.
-- | This is the current method of constructing all the wallets with required distributions
-- | in one go during Plutip startup.
execDistribution :: TestPlanM ContractTest Unit -> Aff ContractTestPlan
execDistribution (MoteT mote) = execWriterT mote <#> go
  where
  -- Recursively go over the tree of test `Description`s and construct a `ContractTestPlan` callback.
  -- When run the `ContractTestPlan` will reconstruct the whole `MoteT` value passed to `execDistribution`
  -- via similar writer effects (plus combining distributions) which append test descriptions
  -- or wrap them in a group.
  go :: Array (Description Aff ContractTest) -> ContractTestPlan
  go = flip execState emptyContractTestPlan <<< traverse_ case _ of
    Test rm { bracket, label, value: ContractTest runTest } ->
      runTest \distr test -> do
        addTests distr $ MoteT
          (tell [ Test rm { bracket, label, value: test } ])
    Group rm { bracket, label, value } -> do
      let ContractTestPlan runGroupPlan = go value
      runGroupPlan \distr tests ->
        addTests distr $ over MoteT
          (censor (pure <<< Group rm <<< { bracket, label, value: _ }))
          tests

  -- This function is used by `go` for iteratively adding Mote tests (internally Writer monad actions)
  -- to the `ContractTestPlan` in the State monad _and_ for combining UTxO distributions used by tests.
  -- Given a distribution and tests (a MoteT value) this runs a `ContractTestPlan`, i.e. passes its
  -- stored distribution and tests to our handler, and then makes a new `ContractTestPlan`, but this time
  -- storing a tuple of stored and passed distributions and also storing a pair of Mote tests, modifying
  -- the previously stored tests to use the first distribution, and the passed tests the second distribution
  --
  -- `go` starts at the top of the test tree and step-by-step constructs a big `ContractTestPlan` which
  -- stores distributions of all inner tests tupled together and tests from the original test tree, which
  -- know how to get their distribution out of the big tuple.
  addTests
    :: forall (distr :: Type) (wallets :: Type)
     . ContractTestPlanHandler distr wallets (State ContractTestPlan Unit)
  addTests distr tests = do
    modify_ \(ContractTestPlan runContractTestPlan) -> runContractTestPlan
      \distr' tests' -> ContractTestPlan \h -> h (distr' /\ distr) do
        mapTest (_ <<< fst) tests'
        mapTest (_ <<< snd) tests

  -- Start with an empty plan, which passes an empty distribution
  -- and an empty array of test `Description`s to the function that
  -- will run tests.
  emptyContractTestPlan :: ContractTestPlan
  emptyContractTestPlan = ContractTestPlan \h -> h unit (pure unit)

-- | Provide a `ContractEnv` connected to Plutip.
-- | Can be used to run multiple `Contract`s using `runContractInEnv`.
-- | Resources which are allocated in the `Aff` computation must be de-allocated
-- | via the `Ref (Array (Aff Unit))` parameter, even if the computation did not
-- | succesfully complete.
-- Startup is implemented sequentially, rather than with nested `Aff.bracket`,
-- to allow non-`Aff` computations to occur between setup and cleanup.
startPlutipContractEnv
  :: forall (distr :: Type) (wallets :: Type)
   . UtxoDistribution distr wallets
  => PlutipConfig
  -> distr
  -> Ref (Array (Aff Unit))
  -> Aff
       { env :: ContractEnv
       , wallets :: wallets
       , printLogs :: Aff Unit
       , clearLogs :: Aff Unit
       }
startPlutipContractEnv plutipCfg distr cleanupRef = do
  configCheck plutipCfg
  tryWithReport startPlutipServer' "Could not start Plutip server"
  (ourKey /\ response) <- tryWithReport startPlutipCluster'
    "Could not start Plutip cluster"
  tryWithReport (startOgmios' response) "Could not start Ogmios"
  tryWithReport (startKupo' response) "Could not start Kupo"
  { env, printLogs, clearLogs } <- makeClusterContractEnv cleanupRef plutipCfg
  wallets <- mkWallets' env ourKey response
  void $ try $ liftEffect do
    for_ env.hooks.onClusterStartup \clusterParamsCb -> do
      clusterParamsCb
        { privateKeys: response.privateKeys <#> unwrap
        , nodeSocketPath: response.nodeSocketPath
        , nodeConfigPath: response.nodeConfigPath
        , privateKeysDirectory: response.keysDirectory
        }
  pure
    { env
    , wallets
    , printLogs
    , clearLogs
    }
  where
  tryWithReport
    :: forall (a :: Type)
     . Aff a
    -> String
    -> Aff a
  tryWithReport what prefix = do
    result <- try what
    case result of
      Left err -> throwError $ error $ prefix <> ": " <> message err
      Right result' -> pure result'

  startPlutipServer' :: Aff Unit
  startPlutipServer' =
    cleanupBracket
      cleanupRef
      (startPlutipServer plutipCfg)
      (stopChildProcessWithPort plutipCfg.port)
      (const $ checkPlutipServer plutipCfg)

  startPlutipCluster'
    :: Aff (PrivatePaymentKey /\ ClusterStartupParameters)
  startPlutipCluster' = do
    let
      distrArray =
        encodeDistribution $
          ourInitialUtxos (encodeDistribution distr) /\
          distr
    for_ distrArray $ traverse_ \n -> when (n < BigNum.fromInt 1_000_000) do
      liftEffect $ throw $ "UTxO is too low: " <> BigNum.toString n <>
        ", must be at least 1_000_000 Lovelace"
    cleanupBracket
      cleanupRef
      (startPlutipCluster plutipCfg distrArray)
      (const $ void $ stopPlutipCluster plutipCfg)
      pure

  startOgmios' :: ClusterStartupParameters -> Aff Unit
  startOgmios' response =
    void
      $ after (startOgmios plutipCfg response)
      $ stopChildProcessWithPort plutipCfg.ogmiosConfig.port

  startKupo' :: ClusterStartupParameters -> Aff Unit
  startKupo' response =
    void
      $ after (startKupo plutipCfg response cleanupRef)
      $ fst
      >>> stopChildProcessWithPort plutipCfg.kupoConfig.port

  mkWallets'
    :: ContractEnv
    -> PrivatePaymentKey
    -> ClusterStartupParameters
    -> Aff wallets
  mkWallets' env ourKey response = do
    runContractInEnv
      env { customLogger = Just (\_ _ -> pure unit) }
      do
        wallets <-
          liftContractM
            "Impossible happened: could not decode wallets. Please report as bug"
            $ decodeWallets distr (coerce response.privateKeys)
        let walletsArray = keyWallets (Proxy :: Proxy distr) wallets
        void $ waitNSlots BigNum.one
        transferFundsFromEnterpriseToBase ourKey walletsArray
        pure wallets

-- Similar to `Aff.bracket`, except cleanup is pushed onto a stack to be run
-- later.
cleanupBracket
  :: forall (a :: Type) (b :: Type)
   . Ref (Array (Aff Unit))
  -> Aff a
  -> (a -> Aff Unit)
  -> (a -> Aff b)
  -> Aff b
cleanupBracket cleanupRef before after action = do
  Aff.bracket
    before
    (\res -> liftEffect $ Ref.modify_ ([ after res ] <> _) cleanupRef)
    action

mkLogging
  :: forall r
   . Record (LogParams r)
  -> Effect
       { updatedConfig :: Record (LogParams r)
       , logger :: Logger
       , customLogger :: Maybe (LogLevel -> Message -> Aff Unit)
       , printLogs :: Aff Unit
       , clearLogs :: Aff Unit
       }
mkLogging cfg
  | cfg.suppressLogs = ado
      -- if logs should be suppressed, setup the machinery and continue with
      -- the bracket
      { addLogEntry, suppressedLogger, printLogs, clearLogs } <-
        setupLogs cfg.logLevel cfg.customLogger
      let
        configLogger = Just $ map liftEffect <<< addLogEntry
      in
        { updatedConfig: cfg { customLogger = configLogger }
        , logger: suppressedLogger
        , customLogger: configLogger
        , printLogs: liftEffect printLogs
        , clearLogs: liftEffect clearLogs
        }
  | otherwise = pure
      -- otherwise, proceed with the env setup and provide a normal logger
      { updatedConfig: cfg
      , logger: mkLogger cfg.logLevel cfg.customLogger
      , customLogger: cfg.customLogger
      , printLogs: pure unit
      , clearLogs: pure unit
      }

-- | Throw an exception if `PlutipConfig` contains ports that are occupied.
configCheck :: PlutipConfig -> Aff Unit
configCheck cfg =
  checkPortsAreFree
    [ { port: cfg.port, service: "plutip-server" }
    , { port: cfg.ogmiosConfig.port, service: "ogmios" }
    , { port: cfg.kupoConfig.port, service: "kupo" }
    ]

-- | Throw an exception if any of the given ports is occupied.
checkPortsAreFree :: Array { port :: UInt, service :: String } -> Aff Unit
checkPortsAreFree ports = do
  occupiedServices <- Array.catMaybes <$> for ports \{ port, service } -> do
    isPortAvailable port <#> if _ then Nothing else Just (port /\ service)
  unless (Array.null occupiedServices) do
    liftEffect $ throw
      $
        "Unable to run the following services, because the ports are occupied:\
        \\n"
      <> foldMap printServiceEntry occupiedServices
  where
  printServiceEntry :: UInt /\ String -> String
  printServiceEntry (port /\ service) =
    "- " <> service <> " (port: " <> show (UInt.toInt port) <> ")\n"

-- | Start the plutip cluster, initializing the state with the given
-- | UTxO distribution. Also initializes an extra payment key (aka
-- | `ourKey`) with some UTxOs for use with further plutip
-- | setup. `ourKey` has funds proportional to the total amount of the
-- | UTxOs in the passed distribution, so it can be used to handle
-- | transaction fees.
startPlutipCluster
  :: PlutipConfig
  -> InitialUTxODistribution
  -> Aff (PrivatePaymentKey /\ ClusterStartupParameters)
startPlutipCluster cfg keysToGenerate = do
  let
    url = mkServerEndpointUrl cfg "start"
    -- TODO: Non-default values for `slotLength` and `epochSize` break staking
    -- rewards, see https://github.com/mlabs-haskell/plutip/issues/149
    epochSize = fromMaybe (UInt.fromInt 80) cfg.clusterConfig.epochSize
  res <- do
    response <- liftAff
      ( Affjax.request
          Affjax.defaultRequest
            { content = Just
                $ RequestBody.String
                $ stringifyAeson
                $ encodeAeson
                $ ClusterStartupRequest
                    { keysToGenerate
                    , epochSize
                    , slotLength: cfg.clusterConfig.slotLength
                    , maxTxSize: cfg.clusterConfig.maxTxSize
                    , raiseExUnitsToMax: cfg.clusterConfig.raiseExUnitsToMax
                    }
            , responseFormat = Affjax.ResponseFormat.string
            , headers = [ Header.ContentType (wrap "application/json") ]
            , url = url
            , method = Left Method.POST
            }
      )
    pure $ response # either
      (Left <<< ClientHttpError)
      \{ body } -> lmap (ClientDecodeJsonError body)
        $ (decodeAeson <=< parseJsonStringToAeson) body
  either (liftEffect <<< throw <<< pprintClientError) pure res >>=
    case _ of
      ClusterStartupFailure reason -> do
        liftEffect $ throw
          $ "Failed to start up cluster. Reason: "
          <> show reason
      ClusterStartupSuccess response@{ privateKeys } ->
        case Array.uncons privateKeys of
          Nothing ->
            liftEffect $ throw $
              "Impossible happened: insufficient private keys provided by plutip. Please report as bug."
          Just { head: PrivateKeyResponse ourKey, tail } ->
            pure $ PrivatePaymentKey ourKey /\ response { privateKeys = tail }

-- | Calculate the initial UTxOs needed for `ourKey` to cover
-- | transaction costs for the given initial distribution
ourInitialUtxos :: InitialUTxODistribution -> InitialUTxOs
ourInitialUtxos utxoDistribution =
  let
    total = Array.foldr (\e acc -> unsafePartial $ fold e # append acc)
      BigNum.zero
      utxoDistribution
  in
    [ -- Take the total value of the UTxOs and add some extra on top
      -- of it to cover the possible transaction fees. Also make sure
      -- we don't request a 0 ada UTxO
      unsafePartial $ append total (BigNum.fromInt 1_000_000)
    ]

stopPlutipCluster :: PlutipConfig -> Aff StopClusterResponse
stopPlutipCluster cfg = do
  let url = mkServerEndpointUrl cfg "stop"
  res <- do
    response <- liftAff
      ( Affjax.request
          Affjax.defaultRequest
            { content = Just
                $ RequestBody.String
                $ stringifyAeson
                $ encodeAeson
                $ StopClusterRequest
            , responseFormat = Affjax.ResponseFormat.string
            , headers = [ Header.ContentType (wrap "application/json") ]
            , url = url
            , method = Left Method.POST
            }
      )
    pure $ response # either
      (Left <<< ClientHttpError)
      \{ body } -> lmap (ClientDecodeJsonError body)
        $ (decodeAeson <=< parseJsonStringToAeson)
            body
  either (liftEffect <<< throw <<< show) pure res

startOgmios
  :: forall r r'
   . { ogmiosConfig :: ServerConfig | r }
  -> { nodeSocketPath :: FilePath
     , nodeConfigPath :: FilePath
     | r'
     }
  -> Aff ManagedProcess
startOgmios cfg params = do
  spawn "ogmios" ogmiosArgs defaultSpawnOptions
    $ Just
    $ _.output
    >>> String.indexOf (Pattern "networkParameters")
    >>> maybe NoOp (const Success)
    >>> pure
  where
  ogmiosArgs :: Array String
  ogmiosArgs =
    [ "--host"
    , cfg.ogmiosConfig.host
    , "--port"
    , UInt.toString cfg.ogmiosConfig.port
    , "--node-socket"
    , params.nodeSocketPath
    , "--node-config"
    , params.nodeConfigPath
    , "--include-transaction-cbor"
    ]

startKupo
  :: forall r r'
   . { kupoConfig :: ServerConfig | r }
  -> { nodeSocketPath :: FilePath
     , nodeConfigPath :: FilePath
     | r'
     }
  -> Ref (Array (Aff Unit))
  -> Aff (ManagedProcess /\ String)
startKupo cfg params cleanupRef = do
  tmpDir <- liftEffect tmpdir
  randomStr <- liftEffect $ uniqueId ""
  let
    workdir = tmpDir <</>> randomStr <> "-kupo-db"
  liftEffect do
    workdirExists <- FSSync.exists workdir
    unless workdirExists (FSSync.mkdir workdir)
  childProcess <-
    after
      (spawnKupoProcess workdir)
      -- set up cleanup
      $ const
      $ liftEffect
      $ addCleanup cleanupRef
      $ liftEffect
      $ _rmdirSync workdir
  pure (childProcess /\ workdir)
  where
  spawnKupoProcess :: FilePath -> Aff ManagedProcess
  spawnKupoProcess workdir =
    spawn "kupo" (kupoArgs workdir) defaultSpawnOptions $
      Just
        ( _.output >>> String.indexOf outputString
            >>> maybe NoOp (const Success)
            >>> pure
        )
    where
    outputString :: Pattern
    outputString = Pattern "ConfigurationCheckpointsForIntersection"

  kupoArgs :: FilePath -> Array String
  kupoArgs workdir =
    [ "--match"
    , "*/*"
    , "--since"
    , "origin"
    , "--workdir"
    , workdir
    , "--host"
    , cfg.kupoConfig.host
    , "--port"
    , UInt.toString cfg.kupoConfig.port
    , "--node-socket"
    , params.nodeSocketPath
    , "--node-config"
    , params.nodeConfigPath
    ]

startPlutipServer :: PlutipConfig -> Aff ManagedProcess
startPlutipServer cfg = do
  spawn "plutip-server" [ "-p", UInt.toString cfg.port ]
    defaultSpawnOptions
    Nothing

checkPlutipServer :: PlutipConfig -> Aff Unit
checkPlutipServer cfg = do
  -- We are trying to call stopPlutipCluster endpoint to ensure that
  -- `plutip-server` has started.
  void
    $ recovering defaultRetryPolicy
        ([ \_ _ -> pure true ])
    $ const
    $ stopPlutipCluster cfg

-- | Kill a process and wait for it to stop listening on a specific port.
stopChildProcessWithPort :: UInt -> ManagedProcess -> Aff Unit
stopChildProcessWithPort port childProcess = do
  stop childProcess
  void $ recovering defaultRetryPolicy ([ \_ _ -> pure true ])
    \_ -> do
      isAvailable <- isPortAvailable port
      unless isAvailable do
        liftEffect $ throw "retry"

type ClusterConfig r =
  ( ogmiosConfig :: ServerConfig
  , kupoConfig :: ServerConfig
  , hooks :: Hooks
  | LogParams r
  )

-- | TODO: Replace original log params with the row type
type LogParams r =
  ( logLevel :: LogLevel
  , customLogger :: Maybe (LogLevel -> Message -> Aff Unit)
  , suppressLogs :: Boolean
  | r
  )

makeNaiveClusterContractEnv
  :: forall r
   . Record (ClusterConfig r)
  -> Logger
  -> Maybe (LogLevel -> Message -> Aff Unit)
  -> Aff ContractEnv
makeNaiveClusterContractEnv cfg logger customLogger = do
  usedTxOuts <- newUsedTxOuts
  backend <- buildBackend logger $ mkCtlBackendParams
    { ogmiosConfig: cfg.ogmiosConfig
    , kupoConfig: cfg.kupoConfig
    }
  ledgerConstants <- getLedgerConstants
    cfg { customLogger = customLogger }
    backend
  backendKnownTxs <- liftEffect $ Ref.new Set.empty
  pure
    { backend
    , handle: mkQueryHandle cfg backend
    , networkId: MainnetId
    , logLevel: cfg.logLevel
    , customLogger: customLogger
    , suppressLogs: cfg.suppressLogs
    , hooks: cfg.hooks
    , wallet: Nothing
    , usedTxOuts
    , ledgerConstants
    -- timeParams have no effect when KeyWallet is used
    , timeParams: defaultTimeParams
    , synchronizationParams: defaultSynchronizationParams
    , knownTxs: { backend: backendKnownTxs }
    }

-- | Makes cluster ContractEnv with configured logs suppression and cleanup scheduled.
makeClusterContractEnv
  :: forall r
   . Ref (Array (Aff Unit))
  -> Record (ClusterConfig r)
  -> Aff
       { env :: ContractEnv
       , clearLogs :: Aff Unit
       , printLogs :: Aff Unit
       }
makeClusterContractEnv cleanupRef cfg = do
  { updatedConfig
  , logger
  , customLogger
  , printLogs
  , clearLogs
  } <- liftEffect $ mkLogging cfg
  cleanupBracket
    cleanupRef
    (makeNaiveClusterContractEnv updatedConfig logger customLogger)
    stopContractEnv
    $ pure
    <<< { env: _, printLogs, clearLogs }

defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy = limitRetriesByCumulativeDelay (Milliseconds 3000.00) $
  constantDelay (Milliseconds 100.0)

mkServerEndpointUrl :: PlutipConfig -> String -> String
mkServerEndpointUrl cfg path = do
  "http://" <> cfg.host <> ":" <> UInt.toString cfg.port <</>> path
