module Main where

import Test.LiquidCheck
import Test.SmallCheck

import Criterion.Main

import JSON
import List
import RBTree

main = defaultMain [
     bgroup "List.insert" $
       [ bgroup (show n)
           [ bench "LiquidCheck" $ testModule "bench/List.hs" [liquidCheck insert "List.insert" n]
           , bench "SmallCheck" $ smallCheck n prop_insert_sc
           ]
       | n <- [2..5]
       ] ++
       [ bgroup (show n)
           [ bench "LiquidCheck" $ testModule "bench/List.hs" [liquidCheck insert "List.insert" n]
           ]
       | n <- [6..7]
       ],
     bgroup "RBTree.add" $
       [ bgroup (show n)
           [ bench "LiquidCheck" $ testModule "bench/RBTree.hs" [liquidCheck (add :: Int -> RBTree Int -> RBTree Int) "RBTree.add" n]
           , bench "SmallCheck" $ smallCheck n prop_add_sc
           ]
       | n <- [2..3]
       ] ++
       [ bgroup (show n)
           [ bench "LiquidCheck" $ testModule "bench/RBTree.hs" [liquidCheck (add :: Int -> RBTree Int -> RBTree Int) "RBTree.add" n]
           ]
       | n <- [4..5]
       ],
     bgroup "JSON.inv" $
       [ bgroup (show n)
           [ bench "LiquidCheck" $ testModule "bench/JSON.hs" [liquidCheck prop_json_inv "JSON.prop_json_inv" n]
           , bench "SmallCheck" $ smallCheck n prop_json_inv
           ]
       | n <- [2..7]
       ]
    ]
