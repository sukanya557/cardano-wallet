{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: MIT
--
-- API type representations of various types. We define here pretty much all our
-- user-facing types that are mostly composed with internal / primitive types.
--
-- This module also define required API instances (JSON, HttpApiData...) for all
-- those types, making sure to match the specification document:
--
-- <https://github.com/input-output-hk/cardano-wallet/blob/master/specifications/api/swagger.yaml Wallet API Specification>

module Cardano.Wallet.Api.Types
    (
    -- * API Types
      ApiAddress (..)
    , ApiWallet (..)
    , WalletBalance (..)
    , WalletPostData (..)
    , WalletPutData (..)
    , WalletPutPassphraseData (..)

    -- * Encoding & Decoding
    , ToText (..)
    , FromText (..)
    , TextDecodingError (..)

    -- * Limits
    , passphraseMinLength
    , passphraseMaxLength
    , walletNameMinLength
    , walletNameMaxLength

    -- * Polymorphic Types
    , ApiT (..)
    , ApiMnemonicT (..)
    , getApiMnemonicT
    ) where

import Prelude

import Cardano.Wallet.Primitive.AddressDerivation
    ( Passphrase (..) )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( AddressPoolGap, getAddressPoolGap, mkAddressPoolGap )
import Cardano.Wallet.Primitive.Mnemonic
    ( CheckSumBits
    , ConsistentEntropy
    , EntropySize
    , entropyToBytes
    , mkMnemonic
    , mnemonicToEntropy
    )
import Cardano.Wallet.Primitive.Types
    ( Address (..)
    , AddressState (..)
    , PoolId (..)
    , ShowFmt (..)
    , WalletBalance (..)
    , WalletDelegation (..)
    , WalletId (..)
    , WalletName (..)
    , WalletPassphraseInfo (..)
    , WalletState (..)
    )
import Control.Arrow
    ( left )
import Control.Monad
    ( (>=>) )
import Data.Aeson
    ( FromJSON (..)
    , SumEncoding (..)
    , ToJSON (..)
    , camelTo2
    , constructorTagModifier
    , fieldLabelModifier
    , genericParseJSON
    , genericToJSON
    , omitNothingFields
    , sumEncoding
    )
import Data.Bifunctor
    ( first )
import Data.ByteString.Base58
    ( bitcoinAlphabet, decodeBase58, encodeBase58 )
import Data.Text
    ( Text )
import Data.Word
    ( Word8 )
import Fmt
    ( Buildable (..) )
import GHC.Generics
    ( Generic )
import GHC.TypeLits
    ( Nat, Symbol )
import Text.Read
    ( readMaybe )

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteArray as BA
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.UUID.Types as UUID

{-------------------------------------------------------------------------------
                                  API Types
-------------------------------------------------------------------------------}

data ApiAddress = ApiAddress
    { id :: !(ApiT Address)
    , state :: !(ApiT AddressState)
    } deriving (Eq, Generic, Show)

data ApiWallet = ApiWallet
    { id :: !(ApiT WalletId)
    , addressPoolGap :: !(ApiT AddressPoolGap)
    , balance :: !(ApiT WalletBalance)
    , delegation :: !(ApiT (WalletDelegation (ApiT PoolId)))
    , name :: !(ApiT WalletName)
    , passphrase :: !(ApiT WalletPassphraseInfo)
    , state :: !(ApiT WalletState)
    } deriving (Eq, Generic, Show)

data WalletPostData = WalletPostData
    { addressPoolGap :: !(Maybe (ApiT AddressPoolGap))
    , mnemonicSentence :: !(ApiMnemonicT '[15,18,21,24] "seed")
    , mnemonicSecondFactor :: !(Maybe (ApiMnemonicT '[9,12] "generation"))
    , name :: !(ApiT WalletName)
    , passphrase :: !(ApiT (Passphrase "encryption"))
    } deriving (Eq, Generic, Show)

newtype WalletPutData = WalletPutData
    { name :: (Maybe (ApiT WalletName))
    } deriving (Eq, Generic, Show)

data WalletPutPassphraseData = WalletPutPassphraseData
    { oldPassphrase :: !(ApiT (Passphrase "encryption"))
    , newPassphrase :: !(ApiT (Passphrase "encryption"))
    } deriving (Eq, Generic, Show)

{-------------------------------------------------------------------------------
                              Polymorphic Types
-------------------------------------------------------------------------------}

-- | Polymorphic wrapper type to put around primitive types and, 3rd party lib
-- types to avoid defining orphan instances and/or, undesirable instances on
-- primitive types. It helps to keep a nice separation of concerns between the
-- API layer and other modules.
newtype ApiT a =
    ApiT { getApiT :: a }
    deriving (Generic, Show, Eq)

-- | Representation of mnemonics at the API-level, using a polymorphic type in
-- the lengths of mnemonics that are supported (and an underlying purpose). In
-- practice, mnemonics correspond to passphrases or seeds, and although they're
-- nice to manipulate as mnemonics from a user-perspective, carrying around a
-- list of words doesn't really make sense for the business logic, which prefers
-- manipulating scrubbed bytes directly.
--
-- @
-- data MyWallet
--     { mnemonic :: ApiMnemonicT '[15,18,21,24] "root-seed"
--     }
-- @
--
-- Note that the given 'Nat's **have** to be valid mnemonic sizes, otherwise the
-- underlying code won't even compile, with not-so-friendly error messages.
--
-- Also, the internal representation holds a @[Text]@ which contains the list of
-- mnemonic words that was parsed. This is only to be able to implement the
-- 'ToJSON' instances and roundtrip, which is a very dubious argument. In
-- practice, we'll NEVER peek at the mnemonic, output them and whatnot.
newtype ApiMnemonicT (sizes :: [Nat]) (purpose :: Symbol) =
    ApiMnemonicT (Passphrase purpose, [Text])
    deriving (Generic, Show, Eq)

getApiMnemonicT :: ApiMnemonicT sizes purpose -> Passphrase purpose
getApiMnemonicT (ApiMnemonicT (pw, _)) = pw

{-------------------------------------------------------------------------------
                             Encoding & Decoding
-------------------------------------------------------------------------------}

-- | Defines a textual encoding for a type defined within the API.
class ToText a where
    -- | Encode the specified value as text.
    toText :: a -> Text

-- | Defines a textual decoding for a type defined within the API.
class FromText a where
    -- | Decode the specified text as a value.
    fromText :: Text -> Either TextDecodingError a

-- | Indicates an error that occurred while decoding from text.
newtype TextDecodingError = TextDecodingError
    { getTextDecodingError :: String }
    deriving stock (Eq, Show)
    deriving newtype Buildable

instance FromText (ApiT Address) where
    -- | Constructs an address from a Base58-encoded string.
    fromText x = maybe
        (Left $ TextDecodingError
            "Unable to decode Address: expected Base58 encoding")
        (pure . ApiT . Address)
        (decodeBase58 bitcoinAlphabet $ T.encodeUtf8 x)

instance ToText (ApiT Address) where
    -- | Converts an address to a Base58-encoded string.
    toText = T.decodeUtf8 . encodeBase58 bitcoinAlphabet . getAddress . getApiT

instance FromText (ApiT AddressPoolGap) where
    fromText t = maybe
        (Left err)
        (fmap ApiT . first (const err) . mkAddressPoolGap)
        (readMaybe @Word8 (T.unpack t))
      where
        err = TextDecodingError $
            "An address pool gap must be a natural number between "
                <> show (fromEnum $ minBound @AddressPoolGap)
                <> " and "
                <> show (fromEnum $ maxBound @AddressPoolGap)

instance ToText (ApiT AddressPoolGap) where
    toText = T.pack . show . getAddressPoolGap . getApiT

instance FromText (ApiT (Passphrase "encryption")) where
    fromText t
        | T.length t < passphraseMinLength =
            Left $ TextDecodingError $
                "passphrase is too short: expected at least "
                <> show passphraseMinLength <> " chars"
        | T.length t > passphraseMaxLength =
            Left $ TextDecodingError $
                "passphrase is too long: expected at most "
                <> show passphraseMaxLength <> " chars"
        | otherwise =
            pure $ ApiT $ Passphrase $ BA.convert $ T.encodeUtf8 t

instance ToText (ApiT (Passphrase "encryption")) where
    toText (ApiT (Passphrase bytes)) = T.decodeUtf8 $ BA.convert bytes

passphraseMinLength :: Int
passphraseMinLength = 10

passphraseMaxLength :: Int
passphraseMaxLength = 255

instance FromText (ApiT WalletId) where
    fromText = maybe
        (Left $ TextDecodingError "A wallet ID must be a valid UUID")
        (Right . ApiT . WalletId)
        . UUID.fromText

instance ToText (ApiT WalletId) where
    toText (ApiT (WalletId i)) = UUID.toText i

instance FromText (ApiT WalletName) where
    fromText t
        | T.length t < walletNameMinLength =
            Left $ TextDecodingError $
                "name is too short: expected at least "
                    <> show walletNameMinLength <> " chars"
        | T.length t > walletNameMaxLength =
            Left $ TextDecodingError $
                "name is too long: expected at most "
                    <> show walletNameMaxLength <> " chars"
        | otherwise =
            return $ ApiT $ WalletName t

instance ToText (ApiT WalletName) where
    toText = getWalletName . getApiT

walletNameMinLength :: Int
walletNameMinLength = 1

walletNameMaxLength :: Int
walletNameMaxLength = 255

instance MkApiMnemonic sizes purpose => FromText (ApiMnemonicT sizes purpose)
  where
    fromText =
        left (TextDecodingError . show)
        . mkApiMnemonic @sizes @purpose
        . T.words

instance ToText (ApiMnemonicT sizes purpose) where
    toText (ApiMnemonicT (!_, xs)) = T.unwords xs

{-------------------------------------------------------------------------------
                               JSON Instances
-------------------------------------------------------------------------------}

instance FromJSON ApiAddress where
    parseJSON = genericParseJSON defaultRecordTypeOptions
instance ToJSON ApiAddress where
    toJSON = genericToJSON defaultRecordTypeOptions

instance FromJSON (ApiT AddressState) where
    parseJSON = fmap ApiT . genericParseJSON defaultSumTypeOptions
instance ToJSON (ApiT AddressState) where
    toJSON = genericToJSON defaultSumTypeOptions . getApiT

instance FromJSON (ApiT Address) where
    parseJSON = parseJSON >=> eitherToParser . left ShowFmt . fromText
instance ToJSON (ApiT Address) where
    toJSON = toJSON . toText

instance FromJSON ApiWallet where
    parseJSON = genericParseJSON defaultRecordTypeOptions
instance ToJSON ApiWallet where
    toJSON = genericToJSON defaultRecordTypeOptions

instance FromJSON WalletPostData where
    parseJSON = genericParseJSON defaultRecordTypeOptions
instance ToJSON  WalletPostData where
    toJSON = genericToJSON defaultRecordTypeOptions

instance FromJSON WalletPutData where
    parseJSON = genericParseJSON defaultRecordTypeOptions
instance ToJSON  WalletPutData where
    toJSON = genericToJSON defaultRecordTypeOptions

instance FromJSON WalletPutPassphraseData where
    parseJSON = genericParseJSON defaultRecordTypeOptions
instance ToJSON  WalletPutPassphraseData where
    toJSON = genericToJSON defaultRecordTypeOptions

instance FromJSON (ApiT (Passphrase "encryption")) where
    parseJSON = parseJSON >=> eitherToParser . left ShowFmt . fromText
instance ToJSON (ApiT (Passphrase "encryption")) where
    toJSON = toJSON . toText

instance {-# OVERLAPS #-}
    ( n ~ EntropySize mw
    , csz ~ CheckSumBits n
    , ConsistentEntropy n mw csz
    , MkApiMnemonic rest purpose
    ) =>
    MkApiMnemonic (mw ': rest) purpose
  where
    mkApiMnemonic parts = either (const parseRest) Right parseMW where
        parseMW = do
            ApiMnemonicT x <- mkApiMnemonic @'[mw] @purpose parts
            return $ ApiMnemonicT x
        parseRest = do
            ApiMnemonicT x <- mkApiMnemonic @rest @purpose parts
            return $ ApiMnemonicT x

instance
    ( n ~ EntropySize mw
    , csz ~ CheckSumBits n
    , ConsistentEntropy n mw csz
    ) =>
    MkApiMnemonic (mw ': '[]) purpose
  where
    mkApiMnemonic parts = do
        m <- first (MkApiMnemonicError . show) (mkMnemonic @mw parts)
        let pwd = Passphrase $ entropyToBytes $ mnemonicToEntropy m
        return $ ApiMnemonicT (pwd, parts)

newtype MkApiMnemonicError = MkApiMnemonicError String
    deriving stock Show
    deriving newtype Buildable

class MkApiMnemonic sizes purpose where
    mkApiMnemonic
        :: [Text] -> Either MkApiMnemonicError (ApiMnemonicT sizes purpose)

instance MkApiMnemonic sizes purpose => FromJSON (ApiMnemonicT sizes purpose)
  where
    parseJSON = parseJSON >=>
        eitherToParser . left ShowFmt . mkApiMnemonic @sizes @purpose

instance ToJSON (ApiMnemonicT sizes purpose) where
    toJSON (ApiMnemonicT (!_, xs)) = toJSON xs

instance FromJSON (ApiT WalletId) where
    parseJSON = parseJSON >=> eitherToParser . left ShowFmt . fromText
instance ToJSON (ApiT WalletId) where
    toJSON = toJSON . toText

instance FromJSON (ApiT AddressPoolGap) where
    parseJSON x = do
        gap <- parseJSON x
        ApiT <$> eitherToParser (mkAddressPoolGap gap)
instance ToJSON (ApiT AddressPoolGap) where
    toJSON = toJSON . getAddressPoolGap . getApiT

instance FromJSON (ApiT WalletBalance) where
    parseJSON = fmap ApiT . genericParseJSON defaultRecordTypeOptions
instance ToJSON (ApiT WalletBalance) where
    toJSON = genericToJSON defaultRecordTypeOptions . getApiT

instance FromJSON (ApiT (WalletDelegation (ApiT PoolId))) where
    parseJSON = fmap ApiT . genericParseJSON walletDelegationOptions
instance ToJSON (ApiT (WalletDelegation (ApiT PoolId))) where
    toJSON = genericToJSON walletDelegationOptions . getApiT

instance FromJSON (ApiT WalletName) where
    parseJSON = parseJSON >=> eitherToParser . left ShowFmt . fromText
instance ToJSON (ApiT WalletName) where
    toJSON = toJSON . toText

instance FromJSON (ApiT WalletPassphraseInfo) where
    parseJSON = fmap ApiT . genericParseJSON defaultRecordTypeOptions
instance ToJSON (ApiT WalletPassphraseInfo) where
    toJSON = genericToJSON defaultRecordTypeOptions . getApiT

instance FromJSON (ApiT WalletState) where
    parseJSON = fmap ApiT . genericParseJSON walletStateOptions
instance ToJSON (ApiT WalletState) where
    toJSON = genericToJSON walletStateOptions . getApiT

instance FromJSON (ApiT PoolId) where
    parseJSON = fmap (ApiT . PoolId) . parseJSON
instance ToJSON (ApiT PoolId) where
    toJSON = toJSON . getPoolId . getApiT

-- | Options for encoding wallet delegation settings. It can be serialized to
-- and from JSON as follows:
--
-- >>> Aeson.encode NotDelegating
-- {"status":"not_delegating"}
--
-- >>> Aeson.encode $ Delegating poolId
-- {"status":"delegating","target": "27522fe5-262e-42a5-8ccb-cef884ea2ba0"}
walletDelegationOptions :: Aeson.Options
walletDelegationOptions = taggedSumTypeOptions $ TaggedObjectOptions
    { _tagFieldName = "status"
    , _contentsFieldName = "target"
    }

-- | Options for encoding a wallet state. It can be serialized to and from JSON
-- as follows:
--
-- >>> Aeson.encode Ready
-- {"status":"ready"}
--
-- >>> Aeson.encode $ Restoring (Quantity 14)
-- {"status":"restoring","progress":{"quantity":14,"unit":"percent"}}

walletStateOptions :: Aeson.Options
walletStateOptions = taggedSumTypeOptions $ TaggedObjectOptions
    { _tagFieldName = "status"
    , _contentsFieldName = "progress"
    }

{-------------------------------------------------------------------------------
                                Aeson Options
-------------------------------------------------------------------------------}

data TaggedObjectOptions = TaggedObjectOptions
    { _tagFieldName :: String
    , _contentsFieldName :: String
    }

defaultSumTypeOptions :: Aeson.Options
defaultSumTypeOptions = Aeson.defaultOptions
    { constructorTagModifier = camelTo2 '_'
    }

defaultRecordTypeOptions :: Aeson.Options
defaultRecordTypeOptions = Aeson.defaultOptions
    { fieldLabelModifier = camelTo2 '_' . dropWhile (== '_')
    , omitNothingFields = True
    }

taggedSumTypeOptions :: TaggedObjectOptions -> Aeson.Options
taggedSumTypeOptions opts = defaultSumTypeOptions
    { sumEncoding = TaggedObject (_tagFieldName opts) (_contentsFieldName opts)
    }

{-------------------------------------------------------------------------------
                                   Helpers
-------------------------------------------------------------------------------}

eitherToParser :: Show s => Either s a -> Aeson.Parser a
eitherToParser = either (fail . show) pure
