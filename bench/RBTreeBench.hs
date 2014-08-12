{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module RBTreeBench where

import           RBTree

import           Test.LiquidCheck
import qualified Test.QuickCheck        as QC
import qualified Test.SmallCheck        as SC
import qualified Test.SmallCheck.Series as SC

--------------------------------------------------------------------------------
-- Testing ---------------------------------------------------------------------
--------------------------------------------------------------------------------
prop_add_lc :: Char -> RBTree Char -> RBTree Char
prop_add_lc = add

isBH (Leaf)         = True
isBH (Node c x l r) = ((isBH l) && (isBH r) && (bh l) == (bh r))

bh (Leaf)         = 0
bh (Node c x l r) = (bh l) + (if (c == R) then 0 else 1)

isRBT t = ord t && isRB t && isBH t

isRB (Leaf)         = True
isRB (Node c x l r) = ((isRB l) && (isRB r) && (c == B || ((isB l) && (isB r))))

isB Leaf = True
isB (Node B _ _ _) = True
isB _ = False

ord Leaf = True
ord (Node c x l r) = ord l && ord r && all (<x) l && all (>x) r
  where all p Leaf = True
        all p (Node _ x l r)
          | p x && all p l && all p r = True
          | otherwise               = False

instance Monad m => SC.Serial m Color
instance (Monad m, SC.Serial m a) => SC.Serial m (RBTree a)

prop_add_sc :: Monad m => Char -> RBTree Char -> SC.Property m
prop_add_sc x t = isRBT t SC.==> isRBT (add x t)

instance QC.Arbitrary Color where
  arbitrary = QC.oneof [return R, return B]

instance QC.Arbitrary a => QC.Arbitrary (RBTree a) where
  arbitrary = QC.sized gen
    where
      gen n
        | n <= 0    = return Leaf
        | otherwise = do c <- QC.arbitrary
                         x <- QC.arbitrary
                         l <- gen (n `div` 2)
                         r <- gen (n `div` 2)
                         return $ Node c x l r

prop_add_qc :: Char -> RBTree Char -> QC.Property
prop_add_qc x t = isRBT t QC.==> isRBT (add x t)