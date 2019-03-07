module Cardano.Wallet.NodeSpec (spec) where

import Prelude

import Test.Hspec
    ( Spec, describe, it, shouldBe )

import Cardano.Wallet.Node

spec :: Spec
spec = do
    describe "Getting next blocks" $ do
        it "should get something from the latest epoch" $ do
            bs <- nextBlocks 1000 (105, 17000)
            length bs `shouldBe` 1000

        it "should get from old epochs" $ do
            bs <- nextBlocks 1000 (104, 10000)
            length bs `shouldBe` 1000