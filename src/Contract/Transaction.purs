-- | A module that defines the different transaction data types, balancing
-- | functionality, transaction fees, signing and submission.
module Contract.Transaction
  ( balanceTx
  , balanceTxE
  , balanceTxWithConstraints
  , balanceTxWithConstraintsE
  , balanceTxs
  , balanceTxsWithConstraints
  , createAdditionalUtxos
  , getTxAuxiliaryData
  , module BalanceTxError
  , module X
  , submit
  , submitE
  , submitTxFromConstraints
  , submitTxFromConstraintsReturningFee
  , withBalancedTx
  , withBalancedTxWithConstraints
  , withBalancedTxs
  , withBalancedTxsWithConstraints
  , lookupTxHash
  , mkPoolPubKeyHash
  , hashTransaction
  ) where

import Prelude

import Cardano.Types
  ( Bech32String
  , Coin
  , PoolPubKeyHash(PoolPubKeyHash)
  , Transaction(Transaction)
  , TransactionHash
  , TransactionInput(TransactionInput)
  , TransactionOutput
  , TransactionUnspentOutput(TransactionUnspentOutput)
  , UtxoMap
  )
import Cardano.Types
  ( DataHash(DataHash)
  , Epoch(Epoch)
  , NativeScript
      ( ScriptPubkey
      , ScriptAll
      , ScriptAny
      , ScriptNOfK
      , TimelockStart
      , TimelockExpiry
      )
  , TransactionHash(TransactionHash)
  , TransactionInput(TransactionInput)
  , TransactionOutput(TransactionOutput)
  , TransactionUnspentOutput(TransactionUnspentOutput)
  ) as X
import Cardano.Types.AuxiliaryData (AuxiliaryData)
import Cardano.Types.Ed25519KeyHash as Ed25519KeyHash
import Cardano.Types.OutputDatum (OutputDatum(OutputDatum, OutputDatumHash)) as X
import Cardano.Types.PoolPubKeyHash (PoolPubKeyHash(PoolPubKeyHash)) as X
import Cardano.Types.ScriptRef (ScriptRef(NativeScriptRef, PlutusScriptRef)) as X
import Cardano.Types.Transaction (Transaction(Transaction), empty) as X
import Cardano.Types.Transaction as Transaction
import Contract.Monad (Contract, runContractInEnv)
import Contract.UnbalancedTx (mkUnbalancedTx)
import Control.Monad.Error.Class (catchError, liftEither, throwError)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Control.Monad.Reader.Class (ask)
import Ctl.Internal.BalanceTx as B
import Ctl.Internal.BalanceTx.Constraints (BalanceTxConstraintsBuilder)
import Ctl.Internal.BalanceTx.Error
  ( Actual(Actual)
  , BalanceTxError
      ( BalanceInsufficientError
      , CouldNotConvertScriptOutputToTxInput
      , CouldNotGetCollateral
      , InsufficientCollateralUtxos
      , CouldNotGetUtxos
      , CollateralReturnError
      , CollateralReturnMinAdaValueCalcError
      , ExUnitsEvaluationFailed
      , InsufficientUtxoBalanceToCoverAsset
      , ReindexRedeemersError
      , UtxoLookupFailedFor
      , UtxoMinAdaValueCalculationFailed
      )
  , Expected(Expected)
  , explainBalanceTxError
  ) as BalanceTxError
import Ctl.Internal.BalanceTx.UnattachedTx (UnindexedTx)
import Ctl.Internal.Contract.AwaitTxConfirmed
  ( awaitTxConfirmed
  , awaitTxConfirmedWithTimeout
  , awaitTxConfirmedWithTimeoutSlots
  , isTxConfirmed
  ) as X
import Ctl.Internal.Contract.MinFee (calculateMinFee) as X
import Ctl.Internal.Contract.Monad (getQueryHandle)
import Ctl.Internal.Contract.QueryHandle.Error (GetTxMetadataError)
import Ctl.Internal.Contract.QueryHandle.Error
  ( GetTxMetadataError
      ( GetTxMetadataTxNotFoundError
      , GetTxMetadataMetadataEmptyOrMissingError
      , GetTxMetadataClientError
      )
  ) as X
import Ctl.Internal.Contract.Sign (signTransaction)
import Ctl.Internal.Contract.Sign (signTransaction) as X
import Ctl.Internal.Lens
  ( _address
  , _amount
  , _auxiliaryData
  , _auxiliaryDataHash
  , _body
  , _certs
  , _collateral
  , _collateralReturn
  , _datum
  , _fee
  , _input
  , _inputs
  , _isValid
  , _mint
  , _networkId
  , _output
  , _outputs
  , _plutusData
  , _plutusScripts
  , _redeemers
  , _referenceInputs
  , _requiredSigners
  , _scriptDataHash
  , _scriptRef
  , _totalCollateral
  , _ttl
  , _validityStartInterval
  , _vkeys
  , _withdrawals
  , _witnessSet
  ) as X
import Ctl.Internal.Lens (_body, _fee, _outputs)
import Ctl.Internal.ProcessConstraints.UnbalancedTx (UnbalancedTx(UnbalancedTx))
import Ctl.Internal.Service.Error (ClientError)
import Ctl.Internal.Types.ScriptLookups (ScriptLookups)
import Ctl.Internal.Types.TxConstraints (TxConstraints)
import Ctl.Internal.Types.UsedTxOuts
  ( UsedTxOuts
  , lockTransactionInputs
  , unlockTransactionInputs
  )
import Data.Array as Array
import Data.Array.NonEmpty as NonEmptyArray
import Data.Bifunctor (lmap)
import Data.Either (Either(Left, Right))
import Data.Foldable (foldl, length)
import Data.Lens.Getter (view)
import Data.Map (Map)
import Data.Map (empty, insert, toUnfoldable) as Map
import Data.Maybe (Maybe(Nothing))
import Data.Newtype (unwrap)
import Data.String.Utils (startsWith)
import Data.Traversable (class Traversable, for_, traverse)
import Data.Tuple (Tuple(Tuple), fst)
import Data.Tuple.Nested (type (/\), (/\))
import Data.UInt (UInt)
import Effect.Aff (bracket, error)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Exception (try)
import Prim.Coerce (class Coercible)
import Prim.TypeError (class Warn, Text)
import Safe.Coerce (coerce)

hashTransaction
  :: Warn (Text "Deprecated: Validator. Use Cardano.Types.PlutusData.hash")
  => Transaction
  -> TransactionHash
hashTransaction = Transaction.hash

-- | Submits a `Transaction`, which is the output of
-- | `signTransaction`.
submit
  :: Transaction
  -> Contract TransactionHash
submit tx = do
  eiTxHash <- submitE tx
  liftEither $ flip lmap eiTxHash \err -> error $
    "Failed to submit tx:\n" <> show err

-- | Submits a `Transaction` that normally should be retreived from
-- | `signTransaction`. Preserves the errors returned by the backend in
-- | the case they need to be inspected.
submitE
  :: Transaction
  -> Contract (Either ClientError TransactionHash)
submitE tx = do
  queryHandle <- getQueryHandle
  eiTxHash <- liftAff $ queryHandle.submitTx tx
  void $ asks (_.hooks >>> _.onSubmit) >>=
    traverse \hook -> liftEffect $ void $ try $ hook tx
  pure eiTxHash

-- | Helper to adapt to UsedTxOuts.
withUsedTxOuts
  :: forall (a :: Type)
   . ReaderT UsedTxOuts Contract a
  -> Contract a
withUsedTxOuts f = asks _.usedTxOuts >>= runReaderT f

-- Helper to avoid repetition.
withTransactions
  :: forall (a :: Type)
       (t :: Type -> Type)
       (ubtx :: Type)
       (tx :: Type)
   . Traversable t
  => (t ubtx -> Contract (t tx))
  -> (tx -> Transaction)
  -> t ubtx
  -> (t tx -> Contract a)
  -> Contract a
withTransactions prepare extract utxs action = do
  env <- ask
  let
    run :: forall (b :: Type). _ b -> _ b
    run = runContractInEnv env
  liftAff $ bracket
    (run (prepare utxs))
    (run <<< cleanup)
    (run <<< action)
  where
  cleanup txs = for_ txs
    (withUsedTxOuts <<< unlockTransactionInputs <<< extract)

withSingleTransaction
  :: forall (a :: Type) (ubtx :: Type) (tx :: Type)
   . (ubtx -> Contract tx)
  -> (tx -> Transaction)
  -> ubtx
  -> (tx -> Contract a)
  -> Contract a
withSingleTransaction prepare extract utx action =
  withTransactions (traverse prepare) extract (NonEmptyArray.singleton utx)
    (action <<< NonEmptyArray.head)

-- | Execute an action on an array of balanced
-- | transactions (`balanceTxs` will be called). Within
-- | this function, all transaction inputs used by these
-- | transactions will be locked, so that they are not used
-- | in any other context.
-- | After the function completes, the locks will be removed.
-- | Errors will be thrown.
withBalancedTxsWithConstraints
  :: forall (a :: Type)
   . Array (UnbalancedTx /\ BalanceTxConstraintsBuilder)
  -> (Array Transaction -> Contract a)
  -> Contract a
withBalancedTxsWithConstraints =
  withTransactions balanceTxsWithConstraints identity

-- | Same as `withBalancedTxsWithConstraints`, but uses the default balancer
-- | constraints.
withBalancedTxs
  :: forall (a :: Type)
   . Array UnbalancedTx
  -> (Array Transaction -> Contract a)
  -> Contract a
withBalancedTxs = withTransactions balanceTxs identity

-- | Execute an action on a balanced transaction (`balanceTx` will
-- | be called). Within this function, all transaction inputs
-- | used by this transaction will be locked, so that they are not
-- | used in any other context.
-- | After the function completes, the locks will be removed.
-- | Errors will be thrown.
withBalancedTxWithConstraints
  :: forall (a :: Type)
   . UnbalancedTx
  -> BalanceTxConstraintsBuilder
  -> (Transaction -> Contract a)
  -> Contract a
withBalancedTxWithConstraints unbalancedTx =
  withSingleTransaction balanceAndLockWithConstraints identity
    <<< Tuple unbalancedTx

-- | Same as `withBalancedTxWithConstraints`, but uses the default balancer
-- | constraints.
withBalancedTx
  :: forall (a :: Type)
   . UnbalancedTx
  -> (Transaction -> Contract a)
  -> Contract a
withBalancedTx = withSingleTransaction balanceAndLock identity

unUnbalancedTx
  :: UnbalancedTx -> UnindexedTx /\ Map TransactionInput TransactionOutput
unUnbalancedTx
  ( UnbalancedTx
      { transaction
      , datums
      , redeemers
      , usedUtxos
      }
  ) =
  { transaction, datums, redeemers } /\ usedUtxos

-- | Attempts to balance an `UnbalancedTx` using the specified
-- | balancer constraints.
-- |
-- | `balanceTxWithConstraints` is a throwing variant.
balanceTxWithConstraintsE
  :: UnbalancedTx
  -> BalanceTxConstraintsBuilder
  -> Contract (Either BalanceTxError.BalanceTxError Transaction)
balanceTxWithConstraintsE tx =
  let
    tx' /\ ix = unUnbalancedTx tx
  in
    B.balanceTxWithConstraints tx' ix

-- | Attempts to balance an `UnbalancedTx` using the specified
-- | balancer constraints.
-- |
-- | 'Throwing' variant of `balanceTxWithConstraintsE`.
balanceTxWithConstraints
  :: UnbalancedTx
  -> BalanceTxConstraintsBuilder
  -> Contract Transaction
balanceTxWithConstraints tx bcb = do
  result <- balanceTxWithConstraintsE tx bcb
  case result of
    Left err -> throwError $ error $ BalanceTxError.explainBalanceTxError err
    Right ftx -> pure ftx

-- | Balance a transaction without providing balancer constraints.
-- |
-- | `balanceTx` is a throwing variant.
balanceTxE
  :: UnbalancedTx
  -> Contract (Either BalanceTxError.BalanceTxError Transaction)
balanceTxE = flip balanceTxWithConstraintsE mempty

-- | Balance a transaction without providing balancer constraints.
-- |
-- | `balanceTxE` is a non-throwing version of this function.
balanceTx :: UnbalancedTx -> Contract Transaction
balanceTx utx = do
  result <- balanceTxE utx
  case result of
    Left err -> throwError $ error $ BalanceTxError.explainBalanceTxError err
    Right ftx -> pure ftx

-- | Balances each transaction using specified balancer constraint sets and
-- | locks the used inputs so that they cannot be reused by subsequent
-- | transactions.
balanceTxsWithConstraints
  :: forall (t :: Type -> Type)
   . Traversable t
  => t (UnbalancedTx /\ BalanceTxConstraintsBuilder)
  -> Contract (t Transaction)
balanceTxsWithConstraints unbalancedTxs =
  unlockAllOnError $ traverse balanceAndLockWithConstraints unbalancedTxs
  where
  unlockAllOnError :: forall (a :: Type). Contract a -> Contract a
  unlockAllOnError f = catchError f $ \e -> do
    for_ unbalancedTxs $
      withUsedTxOuts <<< unlockTransactionInputs <<< uutxToTx <<< fst
    throwError e

  uutxToTx :: UnbalancedTx -> Transaction
  uutxToTx = _.transaction <<< unwrap

-- | Same as `balanceTxsWithConstraints`, but uses the default balancer
-- | constraints.
balanceTxs
  :: forall (t :: Type -> Type)
   . Traversable t
  => t UnbalancedTx
  -> Contract (t Transaction)
balanceTxs = balanceTxsWithConstraints <<< map (flip Tuple mempty)

balanceAndLockWithConstraints
  :: UnbalancedTx /\ BalanceTxConstraintsBuilder
  -> Contract Transaction
balanceAndLockWithConstraints (unbalancedTx /\ constraints) = do
  balancedTx <- balanceTxWithConstraints unbalancedTx constraints
  void $ withUsedTxOuts $ lockTransactionInputs balancedTx
  pure balancedTx

balanceAndLock
  :: UnbalancedTx
  -> Contract Transaction
balanceAndLock = balanceAndLockWithConstraints <<< flip Tuple mempty

-- | Fetch transaction auxiliary data.
-- | Returns `Right` when the transaction exists and auxiliary data is not empty
getTxAuxiliaryData
  :: TransactionHash
  -> Contract (Either GetTxMetadataError AuxiliaryData)
getTxAuxiliaryData txHash = do
  queryHandle <- getQueryHandle
  liftAff $ queryHandle.getTxAuxiliaryData txHash

-- | Builds an expected utxo set from transaction outputs. Predicts output
-- | references (`TransactionInput`s) for each output by calculating the
-- | transaction hash and indexing the outputs in the order they appear in the
-- | transaction. This function should be used for transaction chaining
-- | in conjunction with `mustUseAdditionalUtxos` balancer constraint.
createAdditionalUtxos
  :: forall (tx :: Type)
   . Coercible tx Transaction
  => tx
  -> Contract UtxoMap
createAdditionalUtxos tx = do
  let transactionId = Transaction.hash $ coerce tx
  let
    txOutputs :: Array TransactionOutput
    txOutputs = view (_body <<< _outputs) $ coerce tx

    txIn :: UInt -> TransactionInput
    txIn index = TransactionInput { transactionId, index }

  pure $ txOutputs #
    foldl (\utxo txOut -> Map.insert (txIn $ length utxo) txOut utxo) Map.empty

submitTxFromConstraintsReturningFee
  :: ScriptLookups
  -> TxConstraints
  -> Contract { txHash :: TransactionHash, txFinalFee :: Coin }
submitTxFromConstraintsReturningFee lookups constraints = do
  unbalancedTx <- mkUnbalancedTx lookups constraints
  balancedTx <- balanceTx unbalancedTx
  balancedSignedTx <- signTransaction balancedTx
  txHash <- submit balancedSignedTx
  pure { txHash, txFinalFee: view (_body <<< _fee) balancedSignedTx }

submitTxFromConstraints
  :: ScriptLookups
  -> TxConstraints
  -> Contract TransactionHash
submitTxFromConstraints lookups constraints =
  _.txHash <$> submitTxFromConstraintsReturningFee lookups constraints

lookupTxHash
  :: TransactionHash -> UtxoMap -> Array TransactionUnspentOutput
lookupTxHash txHash utxos =
  map (\(input /\ output) -> TransactionUnspentOutput { input, output })
    $ Array.filter (fst >>> unwrap >>> _.transactionId >>> eq txHash)
    $ Map.toUnfoldable utxos

mkPoolPubKeyHash :: Bech32String -> Maybe PoolPubKeyHash
mkPoolPubKeyHash str
  | startsWith "pool" str = PoolPubKeyHash <$>
      Ed25519KeyHash.fromBech32 str
  | otherwise = Nothing
