{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.MnemonicSpec
    ( spec
    ) where

import Prelude

import Cardano.Wallet.Mnemonic
    ( Entropy
    , EntropyError
    , EntropySize
    , Mnemonic
    , MnemonicException (..)
    , MnemonicWords
    , ambiguousNatVal
    , entropyToByteString
    , entropyToMnemonic
    , genEntropy
    , mkEntropy
    , mkMnemonic
    , mnemonicToEntropy
    , mnemonicToText
    )
import Control.Monad
    ( forM_ )
import Crypto.Encoding.BIP39
    ( ValidChecksumSize, ValidEntropySize, ValidMnemonicSentence, toEntropy )
import Data.ByteString
    ( ByteString )
import Data.Either
    ( isLeft )
import Data.Function
    ( on )
import Data.Text
    ( Text )
import Test.Hspec
    ( Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy )
import Test.Hspec.QuickCheck
    ( prop )
import Test.QuickCheck
    ( Arbitrary, arbitrary, vectorOf, (===) )

import qualified Cardano.Crypto.Wallet as CC
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as T

-- | By default, private keys aren't comparable for security reasons (timing
-- attacks). We allow it here for testing purpose which is fine.
instance Eq CC.XPrv where
    (==) = (==) `on` CC.unXPrv

data TestVector = TestVector
    {
      -- | Text
      string :: Text

      -- | Corresponding Entropy
    , entropy :: Entropy (EntropySize 12)

      -- | Corresponding Mnemonic
    , mnemonic :: Mnemonic 12
    }


spec :: Spec
spec = do
    prop "(9) entropyToMnemonic . mnemonicToEntropy == identity" $
        \e -> (mnemonicToEntropy @9 . entropyToMnemonic @9 @(EntropySize 9)) e == e

    prop "(12) entropyToMnemonic . mnemonicToEntropy == identity" $
        \e -> (mnemonicToEntropy @12 . entropyToMnemonic @12 @(EntropySize 12)) e == e

    prop "(15) entropyToMnemonic . mnemonicToEntropy == identity" $
        \e -> (mnemonicToEntropy @15 . entropyToMnemonic @15 @(EntropySize 15)) e == e

    prop "(9) mkMnemonic . mnemonicToText == pure" $
        \(mw :: Mnemonic 9) -> (mkMnemonic @9 . mnemonicToText) mw === pure mw

    prop "(12) mkMnemonic . mnemonicToText == pure" $
        \(mw :: Mnemonic 12) -> (mkMnemonic @12 . mnemonicToText) mw === pure mw

    prop "(15) mkMnemonic . mnemonicToText == pure" $
        \(mw :: Mnemonic 15) -> (mkMnemonic @15 . mnemonicToText) mw === pure mw

    describe "golden tests" $ do
        it "No empty mnemonic" $
            mkMnemonic @12 [] `shouldSatisfy` isLeft

        it "No empty entropy" $
            mkEntropy @(EntropySize 12) "" `shouldSatisfy` isLeft

        it "Can generate 96 bits entropy" $
            (BS.length . entropyToByteString <$> genEntropy @96) `shouldReturn` 12

        it "Can generate 128 bits entropy" $
            (BS.length . entropyToByteString <$> genEntropy @128) `shouldReturn` 16

        it "Mnemonic to Text" $ forM_ testVectors $ \TestVector{..} ->
            mnemonicToText mnemonic `shouldBe` extractWords string

        it "Mnemonic from Text" $ forM_ testVectors $ \TestVector{..} ->
            (mkMnemonic @12 . extractWords) string `shouldBe` pure mnemonic

        it "Mnemonic from Api is invalid" $ do
            let mnemonicFromApi =
                    "[squirrel,material,silly,twice,direct,slush,pistol,razor,become,junk,kingdom,flee,squirrel,silly,twice]"
            (mkMnemonic @15 . extractWords) mnemonicFromApi `shouldSatisfy` isLeft

        it "Mnemonic to Entropy" $ forM_ testVectors $ \TestVector{..} ->
            mnemonicToEntropy mnemonic `shouldBe` entropy
  where
    testVectors :: [TestVector]
    testVectors =
        [ TestVector "[abandon,abandon,abandon,abandon,abandon,abandon,abandon,abandon,abandon,abandon,abandon,about]"
          (orFail $ mkEntropy'
              "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL")
          (orFail $ mkMnemonic
              ["abandon","abandon","abandon","abandon","abandon","abandon","abandon","abandon","abandon","abandon","abandon","about"])
        , TestVector "[letter,advice,cage,absurd,amount,doctor,acoustic,avoid,letter,advice,cage,above]"
           (orFail $ mkEntropy'
             "\128\128\128\128\128\128\128\128\128\128\128\128\128\128\128\128")
           (orFail $ mkMnemonic
             ["letter","advice","cage","absurd","amount","doctor","acoustic","avoid","letter","advice","cage","above"])
        , TestVector
          "[zoo,zoo,zoo,zoo,zoo,zoo,zoo,zoo,zoo,zoo,zoo,wrong]"
          (orFail $ mkEntropy'
            "\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255\255")
          (orFail $ mkMnemonic
            ["zoo","zoo","zoo","zoo","zoo","zoo","zoo","zoo","zoo","zoo","zoo","wrong"])
        ]
      where
        orFail
            :: Show e
            => Either e a
            -> a
        orFail =
            either (error . (<>) "Failed to create golden Mnemonic: " . show) id

        mkEntropy'
            :: ByteString
            -> Either (EntropyError 4) (Entropy 128)
        mkEntropy' = toEntropy @128 @4 @ByteString

    extractWords
        :: Text
        -> [Text]
    extractWords =
        T.splitOn ","
      . T.dropAround (\c -> c == '[' || c == ']')

-- | The initial seed has to be vector or length multiple of 4 bytes and shorter
-- than 64 bytes. Note that this is good for testing or examples, but probably
-- not for generating truly random Mnemonic words.
--
-- See 'Crypto.Random.Entropy (getEntropy)'
instance
    ( ValidEntropySize n
    , ValidChecksumSize n csz
    ) => Arbitrary (Entropy n) where
    arbitrary =
        let
            size = fromIntegral $ ambiguousNatVal @n
            entropy =
                mkEntropy  @n . B8.pack <$> vectorOf (size `quot` 8) arbitrary
        in
            either (error . show . UnexpectedEntropyError) id <$> entropy

-- | Same remark from 'Arbitrary Entropy' applies here.
instance
    ( n ~ EntropySize mw
    , mw ~ MnemonicWords n
    , ValidChecksumSize n csz
    , ValidEntropySize n
    , ValidMnemonicSentence mw
    , Arbitrary (Entropy n)
    ) => Arbitrary (Mnemonic mw) where
    arbitrary =
        entropyToMnemonic <$> arbitrary @(Entropy n)