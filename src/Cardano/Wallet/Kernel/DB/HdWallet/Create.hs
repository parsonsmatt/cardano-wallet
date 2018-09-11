{-# LANGUAGE RankNTypes #-}

-- | CREATE operations on HD wallets
module Cardano.Wallet.Kernel.DB.HdWallet.Create (
    -- * Errors
    CreateHdRootError(..)
  , CreateHdAccountError(..)
  , CreateHdAddressError(..)
    -- * Functions
  , createHdRoot
  , createHdAccount
  , createHdAddress
    -- * Initial values
  , initHdRoot
  , initHdAccount
  , initHdAddress
  ) where

import           Universum

import           Control.Lens (at, (+~), (.=))
import           Data.SafeCopy (base, deriveSafeCopy)

import           Formatting (bprint, build, sformat, (%))
import qualified Formatting.Buildable

import qualified Pos.Core as Core

import           Cardano.Wallet.Kernel.DB.HdWallet
import           Cardano.Wallet.Kernel.DB.InDb
import           Cardano.Wallet.Kernel.DB.Util.AcidState
import           Cardano.Wallet.Kernel.DB.Util.IxSet (AutoIncrementKey (..),
                     Indexed (..))
import qualified Cardano.Wallet.Kernel.DB.Util.IxSet as IxSet

{-------------------------------------------------------------------------------
  Errors
-------------------------------------------------------------------------------}

-- | Errors thrown by 'createHdWallet'
data CreateHdRootError =
    -- | We already have a wallet with the specified ID
    CreateHdRootExists HdRootId
  | CreateHdRootDefaultAccountCreationFailed
  -- ^ There is a serious bug in the logic, as creating a fresh account on
  -- a fresh wallet should @never@ fail.
  | CreateHdRootDefaultAddressCreationFailed
  -- ^ There is a serious bug in the logic, as creating a fresh address on
  -- a fresh wallet should @never@ fail.

-- | Errors thrown by 'createHdAccount'
data CreateHdAccountError =
    -- | The specified wallet could not be found
    CreateHdAccountUnknownRoot UnknownHdRoot

    -- | Account already exists
  | CreateHdAccountExists HdAccountId

-- | Errors thrown by 'createHdAddress'
data CreateHdAddressError =
    -- | Account not found
    CreateHdAddressUnknown UnknownHdAccount

    -- | Address already used
  | CreateHdAddressExists HdAddressId
  deriving Eq

deriveSafeCopy 1 'base ''CreateHdRootError
deriveSafeCopy 1 'base ''CreateHdAccountError
deriveSafeCopy 1 'base ''CreateHdAddressError

{-------------------------------------------------------------------------------
  CREATE
-------------------------------------------------------------------------------}

-- | Create a new wallet.
-- INVARIANT: Creating a new wallet always come with a fresh HdAccount and
-- a fresh 'HdAddress' attached to it, so we have to pass these two extra
-- piece of into to the update function. We do @not@ build these inside the
-- update function because derivation requires an 'EncryptedSecretKey' and
-- definitely we do not want it to show up in our acid-state logs.
--
createHdRoot :: HdRoot
             -> HdAccount
             -- ^ The default HdAccount to go with this HdRoot
             -> HdAddress
             -- ^ The default HdAddress to go with this HdRoot
             -> Update' CreateHdRootError HdWallets ()
createHdRoot hdRoot defaultHdAccount defaultHdAddress = do
    zoom hdWalletsRoots $ do
      exists <- gets $ IxSet.member rootId
      when exists $ throwError $ CreateHdRootExists rootId
      at rootId .= Just hdRoot

    mapUpdateErrors (const CreateHdRootDefaultAccountCreationFailed) $
        createHdAccount defaultHdAccount
    mapUpdateErrors (const CreateHdRootDefaultAddressCreationFailed) $
        createHdAddress defaultHdAddress

  where
    rootId = hdRoot ^. hdRootId

-- | Create a new account
createHdAccount :: HdAccount -> Update' CreateHdAccountError HdWallets ()
createHdAccount hdAccount = do
    -- Check that the root ID exists
    zoomHdRootId CreateHdAccountUnknownRoot rootId $
      return ()

    zoom hdWalletsAccounts $ do
      exists <- gets $ IxSet.member accountId
      when exists $ throwError $ CreateHdAccountExists accountId
      at accountId .= Just hdAccount
  where
    accountId = hdAccount ^. hdAccountId
    rootId    = accountId ^. hdAccountIdParent

-- | Create a new address
createHdAddress :: HdAddress -> Update' CreateHdAddressError HdWallets ()
createHdAddress hdAddress = do
    -- Check that the account ID exists
    currentPkCounter <-
        zoomHdAccountId CreateHdAddressUnknown (addrId ^. hdAddressIdParent) $ do
            acc <- get
            return (acc ^. hdAccountAutoPkCounter)

    -- Create the new address
    zoom hdWalletsAddresses $ do
      exists <- gets $ IxSet.member addrId
      when exists $ throwError $ CreateHdAddressExists addrId
      at addrId .= Just (Indexed currentPkCounter hdAddress)

    -- Finally, persist the index inside the account. Don't do this earlier
    -- as the creation could still fail, and only here we are sure it will
    -- succeed.
    zoomHdAccountId CreateHdAddressUnknown (addrId ^. hdAddressIdParent) $ do
        modify (hdAccountAutoPkCounter +~ 1)

  where
    addrId = hdAddress ^. hdAddressId

{-------------------------------------------------------------------------------
  Initial values
-------------------------------------------------------------------------------}

-- | New wallet
--
-- The encrypted secret key of the wallet is assumed to be stored elsewhere in
-- some kind of secure key storage; here we ask for the hash of the public key
-- only (i.e., a 'HdRootId'). It is the responsibility of the caller to use the
-- 'BackupPhrase' and (optionally) the 'SpendingPassword' to create a new key
-- add it to the key storage. This is important, because these are secret
-- bits of information that should never end up in the DB log.
initHdRoot :: HdRootId
           -> WalletName
           -> HasSpendingPassword
           -> AssuranceLevel
           -> InDb Core.Timestamp
           -> HdRoot
initHdRoot rootId name hasPass assurance created = HdRoot {
      _hdRootId          = rootId
    , _hdRootName        = name
    , _hdRootHasPassword = hasPass
    , _hdRootAssurance   = assurance
    , _hdRootCreatedAt   = created
    }

-- | New account
--
-- It is the responsibility of the caller to check the wallet's spending
-- password.
initHdAccount :: HdAccountId
              -> HdAccountState
              -> HdAccount
initHdAccount accountId st = HdAccount {
      _hdAccountId    = accountId
    , _hdAccountName  = defName
    , _hdAccountState = st
    , _hdAccountAutoPkCounter = AutoIncrementKey 0
    }
  where
    defName = AccountName $ sformat ("Account: " % build)
                                    (accountId ^. hdAccountIdIx)

-- | New address in the specified account
--
-- Since the DB does not contain the private key of the wallet, we cannot
-- do the actual address derivation here; this will be the responsibility of
-- the caller (which will require the use of the spending password, if
-- one exists).
--
-- Similarly, it will be the responsibility of the caller to pick a random
-- address index, as we do not have access to a random number generator here.
initHdAddress :: HdAddressId
              -> Core.Address
              -> HdAddress
initHdAddress addrId address = HdAddress {
      _hdAddressId      = addrId
    , _hdAddressAddress = InDb address
    }

{-------------------------------------------------------------------------------
  Pretty printing
-------------------------------------------------------------------------------}

instance Buildable CreateHdRootError where
    build (CreateHdRootExists rootId)
        = bprint ("CreateHdRootError::CreateHdRootExists "%build) rootId
    build CreateHdRootDefaultAccountCreationFailed
        = bprint "Invariant violation! CreateHdRootError::CreateHdRootDefaultAccountCreationFailed"
    build CreateHdRootDefaultAddressCreationFailed
        = bprint "Invariant violation! CreateHdRootError::CreateHdRootDefaultAddressCreationFailed"

instance Buildable CreateHdAccountError where
    build (CreateHdAccountUnknownRoot (UnknownHdRoot rootId))
        = bprint ("CreateHdAccountError::CreateHdAccountUnknownRoot "%build) rootId
    build (CreateHdAccountExists accountId)
        = bprint ("CreateHdAccountError::CreateHdAccountExists "%build) accountId

instance Buildable CreateHdAddressError where
  build (CreateHdAddressUnknown unknownRoot)
      = bprint ("CreateHdAddressUnknown: "%build) unknownRoot
  build (CreateHdAddressExists addressId)
      = bprint ("CreateHdAddressExists: "%build) addressId
