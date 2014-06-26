{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DefaultSignatures    #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE ParallelListComp     #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Test.LiquidCheck.Constrain where

import           Control.Applicative
import           Control.Arrow                    (second)
import           Control.Monad.State
import qualified Data.HashMap.Strict              as M
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Proxy
import qualified Data.Text.Lazy                   as T
import           GHC.Generics

import           Encoding                         (zDecodeString)
import           Language.Fixpoint.SmtLib2
import           Language.Fixpoint.Types          hiding (prop)
import           Language.Haskell.Liquid.PredType
import           Language.Haskell.Liquid.RefType
import           Language.Haskell.Liquid.Types    hiding (var)

import           Test.LiquidCheck.Expr
import           Test.LiquidCheck.Gen
import           Test.LiquidCheck.Util


--------------------------------------------------------------------------------
--- Constrainable Data
--------------------------------------------------------------------------------
class Show a => Constrain a where
  getType :: Proxy a -> String
  gen     :: Proxy a -> Int -> SpecType -> Gen String
  stitch  :: Int -> Gen a
  toExpr  :: a -> Expr

  default getType :: (Generic a, GConstrain (Rep a))
                  => Proxy a -> String
  getType p = gtype (reproxyRep p)

  default gen :: (Generic a, GConstrain (Rep a))
              => Proxy a -> Int -> SpecType -> Gen String
  gen p = ggen (reproxyRep p)

  default stitch :: (Generic a, GConstrain (Rep a))
                 => Int -> Gen a
  stitch d = to <$> gstitch d

  default toExpr :: (Generic a, GConstrain (Rep a))
                 => a -> Expr
  toExpr = gtoExpr . from


reproxyElem :: proxy (f a) -> Proxy a
reproxyElem = reproxy



--------------------------------------------------------------------------------
--- Instances
--------------------------------------------------------------------------------
instance Constrain () where
  getType _ = "GHC.Types.()"
  gen _ _ _ = fresh [] (FObj (S "GHC.Types.()"))
  stitch _  = return ()
  toExpr _  = app (stringSymbol "()") []

instance Constrain Int where
  getType _ = "GHC.Types.Int"
  gen _ d t = fresh [] FInt >>= \x ->
    do constrain $ ofReft x (toReft $ rt_reft t)
       -- use the unfolding depth to constrain the range of Ints, like QuickCheck
       _ <- gets depth
       constrain $ var x `ge` fromIntegral (negate d)
       constrain $ var x `le` fromIntegral d
       return x
  stitch _ = read <$> pop
  toExpr i = ECon $ I $ fromIntegral i

instance Constrain Bool
instance Constrain a => Constrain [a]
instance (Constrain a, Constrain b) => Constrain (a,b)

-- instance (Constrain a, Constrain b) => Constrain (a -> b) where
--   getType _ = "FUNCTION"
--   gen p d t = fresh [] (FObj (S "FUNCTION"))
--   stitch  d = return $ \a -> unsafePerformIO $ do
--     error "WHAT GOES HERE??"
--   toExpr  f = error "HOW??"

-- instance Show (a -> b) where
--   show _ = "<function>"

choose :: String -> [String] -> Gen ()
choose x cs
  = do cs <- forM cs $ \c -> do
               addDep x c
               return $ prop c
       constrain $ pOr cs
       constrain $ pAnd [ PNot $ pAnd [x, y]
                        | [x, y] <- filter ((==2) . length) $ subsequences cs ]

-- make :: TH.Name -> [String] -> Sort -> Gen String
make c vs s
  = do x  <- fresh vs s
       t <- (safeFromJust "make" . lookup c) <$> gets ctorEnv
       let (xs, _, rt) = bkArrowDeep t
           su          = mkSubst $ zip (map symbol xs) (map var vs)
       addConstructor (c, rTypeSort mempty t)
       addConstraint $ var x `eq` app c (map var vs)
       constrain $ ofReft x $ subst su $ toReft $ rt_reft rt
       return x

make' c x vs
  = do Just ch <- gets chosen
       mapM_ (addDep ch) vs
       t <- (safeFromJust "make" . lookup c) <$> gets ctorEnv
       let (xs, _, rt) = bkArrowDeep t
           su          = mkSubst $ zip (map symbol xs) (map var vs)
       addConstructor (c, rTypeSort mempty t)
       addConstraint $ prop ch `imp` (var x `eq` app c (map var vs))
       constrain $ ofReft x $ subst su $ toReft $ rt_reft rt

constrain :: Pred -> Gen ()
constrain p
  = do mc <- gets chosen
       case mc of
         Nothing -> addConstraint p
         Just c  -> let p' = prop c `imp` p
                    in addConstraint p'

-- make2 :: forall a b. (Constrain a, Constrain b)
--       => TH.Name -> (Proxy a, Proxy b) -> SpecType -> Sort -> Int -> Gen String
make2 c (pa,pb) t s d
  = do dcp <- fromJust . lookup c <$> gets ctorEnv
       tyi <- gets tyconInfo
       let [t1,t2] = applyPreds (expandRApp (M.fromList []) tyi t) dcp
       x1 <- gen pa (d-1) (snd t1)
       let su = mkSubst [(fst t1, var x1)]
       x2 <- gen pb (d-1) (subst su $ snd t2)
       make c [x1,x2] s

-- make3 :: forall a b c. (Constrain a, Constrain b, Constrain c)
--       => TH.Name -> (Proxy a, Proxy b, Proxy c) -> SpecType -> Sort -> Int -> Gen String
make3 c (pa,pb,pc) t s d
  = do dcp <- fromJust . lookup c <$> gets ctorEnv
       tyi <- gets tyconInfo
       let [t1,t2,t3] = applyPreds (expandRApp (M.fromList []) tyi t) dcp
       x1 <- gen pa (d-1) (snd t1)
       let su = mkSubst [(fst t1, var x1)]
       x2 <- gen pb (d-1) (subst su $ snd t2)
       let su = mkSubst [(fst t1, var x1),(fst t2, var x2)]
       x3 <- gen pc (d-1) (subst su $ snd t3)
       make c [x1,x2,x3] s

make4 c (p1,p2,p3,p4) t s d
  = do dcp <- fromJust . lookup c <$> gets ctorEnv
       tyi <- gets tyconInfo
       let [t1,t2,t3,t4] = applyPreds (expandRApp (M.fromList []) tyi t) dcp
       x1 <- gen p1 (d-1) (snd t1)
       let su = mkSubst [(fst t1, var x1)]
       x2 <- gen p2 (d-1) (subst su $ snd t2)
       let su = mkSubst [(fst t1, var x1),(fst t2, var x2)]
       x3 <- gen p3 (d-1) (subst su $ snd t3)
       let su = mkSubst [(fst t1, var x1),(fst t2, var x2),(fst t3, var x3)]
       x4 <- gen p4 (d-1) (subst su $ snd t4)
       make c [x1,x2,x3,x4] s

make5 c (p1,p2,p3,p4,p5) t s d
  = do dcp <- fromJust . lookup c <$> gets ctorEnv
       tyi <- gets tyconInfo
       let [t1,t2,t3,t4,t5] = applyPreds (expandRApp (M.fromList []) tyi t) dcp
       x1 <- gen p1 (d-1) (snd t1)
       let su = mkSubst [(fst t1, var x1)]
       x2 <- gen p2 (d-1) (subst su $ snd t2)
       let su = mkSubst [(fst t1, var x1),(fst t2, var x2)]
       x3 <- gen p3 (d-1) (subst su $ snd t3)
       let su = mkSubst [(fst t1, var x1),(fst t2, var x2),(fst t3, var x3)]
       x4 <- gen p4 (d-1) (subst su $ snd t4)
       let su = mkSubst [(fst t1, var x1),(fst t2, var x2),(fst t3, var x3),(fst t4, var x4)]
       x5 <- gen p5 (d-1) (subst su $ snd t5)
       make c [x1,x2,x3,x4,x5] s

-- applyPreds :: RApp -> SpecType -> [SpecType]
applyPreds sp dc = zip xs (map tx ts)
  where
    (as, ps, _, t) = bkUniv dc
    (xs, ts, rt)   = bkArrow . snd $ bkClass t
    -- args  = reverse tyArgs
    su    = [(tv, toRSort t, t) | tv <- as | t <- rt_args sp]
    sup   = [(p, r) | p <- ps | r <- rt_pargs sp]
    tx    = (\t -> replacePreds "applyPreds" t sup) . onRefs (monosToPoly sup) . subsTyVars_meet su

onRefs f t@(RVar _ _) = t
onRefs f t = t { rt_pargs = f <$> rt_pargs t }

monosToPoly su r = foldr monoToPoly r su

monoToPoly (p, r) (RMono _ (U _ (Pr [up]) _))
  | pname p == pname up
  = r
monoToPoly _ m = m


-- apply4 :: (Constrain a, Constrain b, Constrain c, Constrain d)
--        => (a -> b -> c -> d -> e) -> Int -> Gen e
apply4 c d
  = do
       v4 <- cons
       v3 <- cons
       v2 <- cons
       v1 <- cons
       return $ c v1 v2 v3 v4
  where
    cons :: Constrain a => Gen a
    cons = stitch (d-1)


ofReft :: String -> Reft -> Pred
ofReft s (Reft (v, rs))
  = let x = mkSubst [(v, var s)]
    in pAnd [subst x p | RConc p <- rs]


reproxyRep :: Proxy a -> Proxy (Rep a a)
reproxyRep = reproxy


--------------------------------------------------------------------------------
--- Sums of Products
--------------------------------------------------------------------------------
class GConstrain f where
  gtype        :: Proxy (f a) -> String
  ggen         :: Proxy (f a) -> Int    -> SpecType -> Gen String
  gstitch      :: Int -> Gen (f a)
  gtoExpr      :: f a -> Expr

reproxyGElem :: Proxy (M1 d c f a) -> Proxy (f a)
reproxyGElem = reproxy

instance (Datatype c, GConstrainSum f) => GConstrain (D1 c f) where
  gtype p = qualifiedDatatypeName (undefined :: D1 c f a)

  ggen p d t
    = inModule mod . making sort $ do
        x  <- fresh [] sort
        xs <- ggenAlts (reproxyGElem p) x d t
        choose x xs
        constrain $ ofReft x $ toReft $ rt_reft t
        return x
    where
      mod  = GHC.Generics.moduleName (undefined :: D1 c f a)
      sort = qualifiedSort (undefined :: D1 c f a)

  gstitch d = M1 <$> making sort (fst <$> gstitchAlts d)
    where
      sort = qualifiedSort (undefined :: D1 c f a)

  gtoExpr c@(M1 x) = app (qualify c (symbolString $ val d)) xs
    where
      (EApp d xs) = gtoExprAlts x

instance (Constrain a) => GConstrain (K1 i a) where
  gtype p    = getType (reproxy p :: Proxy a)
  ggen p d t = gen (reproxy p :: Proxy a) d t
  gstitch d  = K1 <$> stitch d
  gtoExpr (K1 x) = toExpr x

qualify :: Datatype d => D1 d f a -> String -> String
qualify d x = GHC.Generics.moduleName d ++ "." ++ x

qualifiedDatatypeName :: Datatype d => D1 d f a -> String
qualifiedDatatypeName d = qualify d (datatypeName d)

qualifiedSort :: Datatype d => D1 d f a -> Sort
qualifiedSort d = FObj $ symbol $ qualifiedDatatypeName d

--------------------------------------------------------------------------------
--- Sums
--------------------------------------------------------------------------------
class GConstrainSum f where
  ggenAlts      :: Proxy (f a) -> String -> Int -> SpecType -> Gen [String]
  gstitchAlts   :: Int -> Gen (f a, Bool)
  gtoExprAlts   :: f a -> Expr

reproxyLeft :: Proxy ((c (f :: * -> *) (g :: * -> *)) a) -> Proxy (f a)
reproxyLeft = reproxy

reproxyRight :: Proxy ((c (f :: * -> *) (g :: * -> *)) a) -> Proxy (g a)
reproxyRight = reproxy

instance (GConstrainSum f, GConstrainSum g) => GConstrainSum (f :+: g) where
  ggenAlts p v d t
    = do xs <- ggenAlts (reproxyLeft p) v d t
         ys <- ggenAlts (reproxyRight p) v d t
         return $! xs++ys

  gstitchAlts d
    = do (g,cg) <- gstitchAlts d
         (f,cf) <- gstitchAlts d
         case (cf,cg) of
           (True,_) -> return (L1 f, True)
           (_,True) -> return (R1 g, True)
           _        -> return (error "gstitchAlts :+: CANNOT HAPPEN", False)

  gtoExprAlts (L1 x) = gtoExprAlts x
  gtoExprAlts (R1 x) = gtoExprAlts x

instance (Constructor c, GConstrainProd f) => GConstrainSum (C1 c f) where
  ggenAlts p v 1 t
    = do ty <- gets makingTy
         if gisRecursive p ty
           then return []
           else pure <$> ggenAlt p v 1 t
  ggenAlts p v d t = pure <$> ggenAlt p v d t

  gstitchAlts 1
    = do ty <- gets makingTy
         if gisRecursive (Proxy :: Proxy (C1 c f a)) ty
           then return (error "gstitchAlts C1 CANNOT HAPPEN", False)
           else gstitchAlt 1
  gstitchAlts d
    = gstitchAlt d

  gtoExprAlts c@(M1 x)  = app (symbol $ conName c) (gtoExprs x)

gisRecursive :: (Constructor c, GConstrainProd f)
             => Proxy (C1 c f a) -> Sort -> Bool
gisRecursive (p :: Proxy (C1 c f a)) t
  = zDecodeString (T.unpack $ smt2 t) `elem` gconArgTys (reproxyGElem p)

ggenAlt :: (Constructor c, GConstrainProd f)
        => Proxy (C1 c f a) -> String -> Int -> SpecType -> Gen String
ggenAlt (p :: Proxy (C1 c f a)) x d t
  = withFreshChoice $ \ch -> do
     let cn = conName (undefined :: C1 c f a)
     mod <- gets modName
     dcp <- safeFromJust "ggenAlt" . lookup (mod++"."++cn) <$> gets ctorEnv
     tyi <- gets tyconInfo
     let ts = applyPreds (expandRApp (M.fromList []) tyi t) dcp
     xs  <- ggenArgs (reproxyGElem p) d ts
     make' (mod++"."++cn) x xs

gstitchAlt :: GConstrainProd f => Int -> Gen (C1 c f a, Bool)
gstitchAlt d
  = do x <- gstitchArgs d
       c <- popChoice
       return (M1 x, c)

--------------------------------------------------------------------------------
--- Products
--------------------------------------------------------------------------------
class GConstrainProd f where
  gconArgTys  :: Proxy (f a) -> [String]
  ggenArgs    :: Proxy (f a) -> Int -> [(Symbol,SpecType)] -> Gen [String]
  gstitchArgs :: Int -> Gen (f a)
  gtoExprs    :: f a -> [Expr]

instance (GConstrainProd f, GConstrainProd g) => GConstrainProd (f :*: g) where
  gconArgTys p = gconArgTys (reproxyLeft p) ++ gconArgTys (reproxyRight p)

  ggenArgs p d ts
    = do xs <- ggenArgs (reproxyLeft p) d ts
         let su = mkSubst $ zipWith (\x t -> (fst t, var x)) xs ts
         let ts' = drop (length xs) ts
         ys <- ggenArgs (reproxyRight p) d (map (second (subst su)) ts')
         return $ xs ++ ys

  gstitchArgs d
    = do ys <- gstitchArgs d
         xs <- gstitchArgs d
         return $ xs :*: ys

  gtoExprs (f :*: g) = gtoExprs f ++ gtoExprs g

instance (GConstrain f) => GConstrainProd (S1 c f) where
  gconArgTys p        = [gtype (reproxyGElem p)]
  ggenArgs p d (t:ts) = sequence [ggen (reproxyGElem p) (d-1) (snd t)]
  gstitchArgs d       = M1 <$> gstitch (d-1)
  gtoExprs (M1 x)     = [gtoExpr x]

instance GConstrainProd U1 where
  gconArgTys p    = []
  ggenArgs p d [] = return []
  gstitchArgs d   = return U1
  gtoExprs _      = []