module Ctl.Examples.ExUnits where

import Contract.Prelude

import Cardano.Types.BigNum as BigNum
import Cardano.Types.Credential (Credential(ScriptHashCredential))
import Cardano.Types.PlutusData (unit) as PlutusData
import Contract.Address (mkAddress)
import Contract.Config (ContractParams, testnetNamiConfig)
import Contract.Credential (Credential(PubKeyHashCredential))
import Contract.Log (logInfo')
import Contract.Monad (Contract, launchAff_, runContract)
import Contract.PlutusData (RedeemerDatum(RedeemerDatum), toData)
import Contract.ScriptLookups as Lookups
import Contract.Scripts (Validator, ValidatorHash, validatorHash)
import Contract.TextEnvelope (decodeTextEnvelope, plutusScriptFromEnvelope)
import Contract.Transaction
  ( TransactionHash
  , _input
  , awaitTxConfirmed
  , lookupTxHash
  , submitTxFromConstraints
  )
import Contract.TxConstraints (TxConstraints)
import Contract.TxConstraints as Constraints
import Contract.Utxos (utxosAt)
import Contract.Value as Value
import Contract.Wallet (ownStakePubKeyHashes)
import Control.Monad.Error.Class (liftMaybe)
import Data.Array (head)
import Data.Lens (view)
import Effect.Exception (error)
import JS.BigInt (BigInt)
import JS.BigInt as BigInt

main :: Effect Unit
main = example testnetNamiConfig

contract :: Contract Unit
contract = do
  logInfo' "Running Examples.ExUnits"
  validator <- exUnitsScript
  let vhash = validatorHash validator
  logInfo' "Attempt to lock value"
  txId <- payToExUnits vhash
  awaitTxConfirmed txId
  logInfo' "Tx submitted successfully, Try to spend locked values"
  spendFromExUnits (BigInt.fromInt 1000) vhash validator txId

example :: ContractParams -> Effect Unit
example cfg = launchAff_ do
  runContract cfg contract

payToExUnits :: ValidatorHash -> Contract TransactionHash
payToExUnits vhash = do
  -- Send to own stake credential. This is used to test mustPayToScriptAddress.
  mbStakeKeyHash <- join <<< head <$> ownStakePubKeyHashes
  let
    constraints :: TxConstraints
    constraints =
      case mbStakeKeyHash of
        Nothing ->
          Constraints.mustPayToScript vhash PlutusData.unit
            Constraints.DatumWitness
            $ Value.lovelaceValueOf
            $ BigNum.fromInt 2_000_000
        Just stakeKeyHash ->
          Constraints.mustPayToScriptAddress vhash
            (PubKeyHashCredential $ unwrap stakeKeyHash)
            PlutusData.unit
            Constraints.DatumWitness
            $ Value.lovelaceValueOf
            $ BigNum.fromInt 2_000_000

    lookups :: Lookups.ScriptLookups
    lookups = mempty

  submitTxFromConstraints lookups constraints

-- | ExUnits script loops a given number of iterations provided as redeemer.
spendFromExUnits
  :: BigInt
  -> ValidatorHash
  -> Validator
  -> TransactionHash
  -> Contract Unit
spendFromExUnits iters vhash validator txId = do
  -- Use own stake credential if available
  mbStakeKeyHash <- join <<< head <$> ownStakePubKeyHashes
  scriptAddress <-
    mkAddress (wrap $ ScriptHashCredential vhash)
      (wrap <<< PubKeyHashCredential <<< unwrap <$> mbStakeKeyHash)
  utxos <- utxosAt scriptAddress
  txInput <-
    liftM
      ( error
          ( "The id "
              <> show txId
              <> " does not have output locked at: "
              <> show scriptAddress
          )
      )
      (view _input <$> head (lookupTxHash txId utxos))
  let
    lookups :: Lookups.ScriptLookups
    lookups = mconcat
      [ Lookups.validator validator
      , Lookups.unspentOutputs utxos
      , Lookups.datum PlutusData.unit
      ]

    constraints :: TxConstraints
    constraints =
      Constraints.mustSpendScriptOutput txInput (RedeemerDatum $ toData iters)

  spendTxId <- submitTxFromConstraints lookups constraints
  awaitTxConfirmed spendTxId
  logInfo' "Successfully spent locked values."

exUnitsScript :: Contract Validator
exUnitsScript = do
  liftMaybe (error "Error decoding exUnits") do
    envelope <- decodeTextEnvelope exUnits
    plutusScriptFromEnvelope envelope

foreign import exUnits :: String
