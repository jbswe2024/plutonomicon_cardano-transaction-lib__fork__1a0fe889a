-- | This module balances and signs two transactions at once and demonstrates
-- | the `withBalancedandSignedTxs` bracket. The point is that two different
-- | Utxos will be used for these transactions.
module Ctl.Examples.SignMultiple (example, contract, main) where

import Contract.Prelude

import Contract.Address
  ( ownPaymentPubKeysHashes
  , ownStakePubKeysHashes
  )
import Contract.Config (ConfigParams, testnetNamiConfig)
import Contract.Log (logInfo')
import Contract.Monad
  ( Contract
  , launchAff_
  , liftedE
  , liftedM
  , runContract
  , throwContractError
  )
import Contract.ScriptLookups as Lookups
import Contract.Transaction
  ( BalancedSignedTransaction
  , TransactionHash
  , awaitTxConfirmed
  , signTransaction
  , submit
  , withBalancedTxs
  )
import Contract.TxConstraints as Constraints
import Contract.Utxos (getWalletUtxos)
import Contract.Value (leq)
import Contract.Value as Value
import Control.Monad.Reader (asks)
import Data.Array (head)
import Data.BigInt as BigInt
import Data.Map (Map, filter)
import Data.Set (Set)
import Data.UInt (UInt)
import Effect.Ref as Ref

getLockedInputs
  :: forall (r :: Row Type). Contract r (Map TransactionHash (Set UInt))
getLockedInputs = do
  cache <- asks (_.usedTxOuts <<< _.runtime <<< unwrap)
  liftEffect $ Ref.read $ unwrap cache

main :: Effect Unit
main = example testnetNamiConfig

contract :: Contract () Unit
contract = do
  logInfo' "Running Examples.SignMultiple"
  pkh <- liftedM "Failed to get own PKH" $ head <$> ownPaymentPubKeysHashes
  skh <- liftedM "Failed to get own SKH" $ join <<< head <$>
    ownStakePubKeysHashes

  -- Early fail if not enough utxos present for 2 transactions
  unlessM hasSufficientUtxos $ throwContractError
    "Insufficient Utxos for 2 transactions"

  let
    constraints :: Constraints.TxConstraints Void Void
    constraints = Constraints.mustPayToPubKeyAddress pkh skh
      $ Value.lovelaceValueOf
      $ BigInt.fromInt 2_000_000

    lookups :: Lookups.ScriptLookups Void
    lookups = mempty

  unbalancedTx0 <- liftedE $ Lookups.mkUnbalancedTx lookups constraints
  unbalancedTx1 <- liftedE $ Lookups.mkUnbalancedTx lookups constraints

  txIds <- withBalancedTxs [ unbalancedTx0, unbalancedTx1 ] $ \balancedTxs -> do
    locked <- getLockedInputs
    logInfo' $ "Locked inputs inside bracket (should be nonempty): "
      <> show locked
    traverse (submitAndLog <=< signTransaction) balancedTxs

  locked <- getLockedInputs
  logInfo' $ "Locked inputs after bracket (should be empty): " <> show locked

  case txIds of
    [ txId0, txId1 ] -> do
      awaitTxConfirmed txId0
      logInfo' $ "Tx 0 submitted successfully!"
      awaitTxConfirmed txId1
      logInfo' $ "Tx 1 submitted successfully!"
    _ -> throwContractError "Unexpected error - no transaction IDs"

  where
  submitAndLog
    :: forall (r :: Row Type)
     . BalancedSignedTransaction
    -> Contract r TransactionHash
  submitAndLog bsTx = do
    txId <- submit bsTx
    logInfo' $ "Tx ID: " <> show txId
    pure txId

  hasSufficientUtxos :: forall (r :: Row Type). Contract r Boolean
  hasSufficientUtxos = do
    let
      -- 4 Ada: enough to cover 2 Ada transfer and fees
      isUtxoValid u = leq (Value.lovelaceValueOf $ BigInt.fromInt 4_000_000)
        (unwrap (unwrap u).output).amount

    walletValidUtxos <- liftedM "Failed to get wallet Utxos"
      $ map (length <<< filter isUtxoValid)
      <$> getWalletUtxos

    pure $ walletValidUtxos >= 2 -- 2 transactions

example :: ConfigParams () -> Effect Unit
example cfg = launchAff_ do
  runContract cfg contract
