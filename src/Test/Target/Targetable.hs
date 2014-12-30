{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE DefaultSignatures    #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Test.Target.Targetable
  ( Targetable(..)
  , apply
  , oneOf
  , unapply
  , constrain
  , ofReft
  ) where

import           Control.Applicative
import           Control.Arrow                   (second)
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Char
import qualified Data.HashMap.Strict             as M
import           Data.List
import           Data.Monoid
import           Data.Proxy
import           Data.Ratio
import qualified Data.Text                       as T
import           Data.Word                       (Word8)
import           GHC.Generics

import           Language.Fixpoint.Types         hiding (prop, ofReft)
import           Language.Haskell.Liquid.RefType
import           Language.Haskell.Liquid.Types   hiding (var)

import           Test.Target.Expr
import           Test.Target.Eval
import           Test.Target.Monad
import           Test.Target.Types

-- import Debug.Trace

--------------------------------------------------------------------------------
--- Constrainable Data
--------------------------------------------------------------------------------
class Targetable a where
  getType :: Proxy a -> Sort
  query   :: Proxy a -> Int -> SpecType -> Gen Symbol
  toExpr  :: a -> Expr

  decode  :: Symbol -> SpecType -> Gen a
  check   :: a -> SpecType -> Gen (Bool, Expr)

  default getType :: (Generic a, Rep a ~ D1 d f, Datatype d)
                  => Proxy a -> Sort
  getType _ = FObj $ qualifiedDatatypeName (undefined :: Rep a a)

  default query :: (Generic a, GQuery (Rep a))
              => Proxy a -> Int -> SpecType -> Gen Symbol
  query p = gquery (reproxyRep p)

  default toExpr :: (Generic a, GToExpr (Rep a))
                 => a -> Expr
  toExpr = gtoExpr . from

  default decode :: (Generic a, GDecode (Rep a))
                 => Symbol -> SpecType -> Gen a
  decode v _ = do
    x <- whichOf v
    (c, fs) <- unapply x
    to <$> gdecode c fs

  default check :: (Generic a, GCheck (Rep a))
                => a -> SpecType -> Gen (Bool, Expr)
  check v t = gcheck (from v) t

reproxy :: proxy a -> Proxy b
reproxy _ = Proxy
{-# INLINE reproxy #-}

reproxyElem :: proxy (f a) -> Proxy a
reproxyElem = reproxy
{-# INLINE reproxyElem #-}



--------------------------------------------------------------------------------
--- Instances
--------------------------------------------------------------------------------
instance Targetable () where
  getType _ = FObj "GHC.Tuple.()"
  query _ _ _ = fresh (FObj "GHC.Tuple.()")
  -- this is super fiddly, but seemingly required since GHC.exprType chokes on "GHC.Tuple.()"
  toExpr _   = app ("()" :: Symbol) []

  decode _ _ = return ()
  check _ t = do
    let e = app ("()" :: Symbol) []
    b <- eval e $ toReft $ rt_reft t
    return (b,e)

instance Targetable Int where
  getType _ = FObj "GHC.Types.Int"
  query _ d t = fresh FInt >>= \x ->
    do constrain $ ofReft (var x) (toReft $ rt_reft t)
       -- use the unfolding depth to constrain the range of Ints, like QuickCheck
       constrain $ var x `ge` fromIntegral (negate d)
       constrain $ var x `le` fromIntegral d
       return x
  toExpr i = ECon $ I $ fromIntegral i

  decode v _ = read . T.unpack <$> getValue v

  check v t = do
    let e = fromIntegral v
    b <- eval e $ toReft $ rt_reft t
    return (b, e)

instance Targetable Integer where
  getType _ = FObj "GHC.Integer.Type.Integer"
  query _ d t = query (Proxy :: Proxy Int) d t
  toExpr  x = toExpr (fromIntegral x :: Int)

  decode v t = decode v t >>= \(x::Int) -> return . fromIntegral $ x

  check v t = do
    let e = fromIntegral v
    b <- eval e $ toReft $ rt_reft t
    return (b, e)

instance Targetable Char where
  getType _ = FObj "GHC.Types.Char"
  query _ d t = fresh FInt >>= \x ->
    do constrain $ var x `ge` 0
       constrain $ var x `le` fromIntegral d
       constrain $ ofReft (var x) (toReft $ rt_reft t)
       return x
  toExpr  c = ESym $ SL $ T.singleton c

  decode v t = decode v t >>= \(x::Int) -> return . chr $ x + ord 'a'

  check v t = do
    let e = ESym $ SL $ T.singleton v
    b <- eval e $ toReft $ rt_reft t
    return (b, e)

instance Targetable Word8 where
  getType _ = FObj "GHC.Word.Word8"
  query _ d t = fresh FInt >>= \x ->
    do _ <- asks depth
       constrain $ var x `ge` 0
       constrain $ var x `le` fromIntegral d
       constrain $ ofReft (var x) (toReft $ rt_reft t)
       return x
  toExpr i   = ECon $ I $ fromIntegral i

  decode v t = decode v t >>= \(x::Int) -> return $ fromIntegral x

  check v t = do
    let e = fromIntegral v
    b <- eval e $ toReft $ rt_reft t
    return (b, e)

instance Targetable Bool where
  getType _ = FObj "GHC.Types.Bool"
  query _ _ t = fresh boolsort >>= \x ->
    do constrain $ ofReft (var x) (toReft $ rt_reft t)
       return x

  decode v _ = getValue v >>= \case
    "true"  -> return True
    "false" -> return False


instance Targetable a => Targetable [a]
instance Targetable a => Targetable (Maybe a)
instance (Targetable a, Targetable b) => Targetable (Either a b)
instance (Targetable a, Targetable b) => Targetable (a,b)
instance (Targetable a, Targetable b, Targetable c) => Targetable (a,b,c)


instance (Num a, Integral a, Targetable a) => Targetable (Ratio a) where
  getType _ = FObj "GHC.Real.Ratio"
  query _ d t = query (Proxy :: Proxy Int) d t
  decode v t= decode v t >>= \ (x::Int) -> return (fromIntegral x)
  -- query _ d t = fresh (FObj "GHC.Real.Ratio") >>= \x ->
  --   do query (Proxy :: Proxy Int) d t
  --      query (Proxy :: Proxy Int) d t
  --      return x
  -- stitch d t = do x :: Int <- stitch d t
  --                 y' :: Int <- stitch d t
  --                 -- we should really modify `t' above to have Z3 generate non-zero denoms
  --                 let y = if y' == 0 then 1 else y'
  --                 let toA z = fromIntegral z :: a
  --                 return $ toA x % toA y
  toExpr x = EApp (dummyLoc "GHC.Real.:%") [toExpr (numerator x), toExpr (denominator x)]
  check = undefined

-- | Given a data constructor @d@ and a list of expressions @xs@, construct a
-- new expression corresponding to @d xs@.
apply :: Symbol -> [Expr] -> Gen Expr
apply c vs = do 
  mc <- gets chosen
  case mc of
    Just ch -> mapM_ (addDep ch) vs
    Nothing -> return ()
  let x = app c vs
  t <- lookupCtor c
  let (xs, _, rt) = bkArrowDeep t
      su          = mkSubst $ zip (map symbol xs) vs
  addConstructor (c, rTypeSort mempty t)
  constrain $ ofReft x $ subst su $ toReft $ rt_reft rt
  return x

-- | Given a symbolic variable and a list of @(choice, var)@ pairs,
-- @oneOf x choices@ asserts that @x@ must equal one of the @var@s in
-- @choices@.
oneOf :: Symbol -> [(Expr,Expr)] -> Gen ()
oneOf x cs
  = do cs <- forM cs $ \(y,c) -> do
               addDep x c
               constrain $ prop c `imp` (var x `eq` y)
               return $ prop c
       constrain $ pOr cs
       constrain $ pAnd [ PNot $ pAnd [x, y]
                        | [x, y] <- filter ((==2) . length) $ subsequences cs ]

-- | Split a symbolic variable representing the application of a data
-- constructor into a pair of the data constructor and the sub-variables.
unapply :: Symbol -> Gen (Symbol, [Symbol])
unapply c = do
  let [_,cn,_] = T.splitOn "-" $ symbolText c
  deps <- gets deps
  return (symbol cn, M.lookupDefault [] c deps)

-- | Assert a logical predicate, guarded by the current choice variable.
constrain :: Pred -> Gen ()
constrain p = do
  mc <- gets chosen
  case mc of
    Nothing -> addConstraint p
    Just c  -> let p' = prop (var c) `imp` p
               in addConstraint p'

-- | Given an expression @e@ and a refinement @{v | p}@, construct
-- the predicate @p[e/v]@.
ofReft :: Expr -> Reft -> Pred
ofReft e (Reft (v, rs))
  = let x = mkSubst [(v, e)]
    in pAnd [subst x p | RConc p <- rs]

reproxyRep :: Proxy a -> Proxy (Rep a a)
reproxyRep = reproxy


--------------------------------------------------------------------------------
--- Sums of Products
--------------------------------------------------------------------------------
class GToExpr f where
  gtoExpr      :: f a -> Expr

class GQuery f where
  gquery       :: Proxy (f a) -> Int -> SpecType -> Gen Symbol

class GDecode f where
  gdecode      :: Symbol -> [Symbol] -> Gen (f a)

class GCheck f where
  gcheck       :: f a -> SpecType -> Gen (Bool, Expr)

reproxyGElem :: Proxy (M1 d c f a) -> Proxy (f a)
reproxyGElem = reproxy

instance (Datatype c, GToExprCtor f) => GToExpr (D1 c f) where
  gtoExpr (M1 x) = app (qualify mod (symbolString $ val d)) xs
    where
      mod  = GHC.Generics.moduleName (undefined :: D1 c f a)
      (EApp d xs) = gtoExprCtor x

instance (Datatype c, GQueryCtors f) => GQuery (D1 c f) where
  gquery p d t = inModule mod . making sort $ do
    xs <- gqueryCtors (reproxyGElem p) d t
    x  <- fresh sort
    oneOf x xs
    constrain $ ofReft (var x) $ toReft $ rt_reft t
    return x
   where
     mod  = symbol $ GHC.Generics.moduleName (undefined :: D1 c f a)
     sort = FObj $ qualifiedDatatypeName (undefined :: D1 c f a)

instance (Datatype c, GDecode f) => GDecode (D1 c f) where
  gdecode c vs = M1 <$> making sort (gdecode c vs)
    where
      sort = FObj $ qualifiedDatatypeName (undefined :: D1 c f a)

instance (Datatype c, GCheck f) => GCheck (D1 c f) where
  gcheck (M1 x) t = inModule mod . making sort $ gcheck x t
    where
      mod  = symbol $ GHC.Generics.moduleName (undefined :: D1 c f a)
      sort = FObj $ qualifiedDatatypeName (undefined :: D1 c f a)


instance (Targetable a) => GToExpr (K1 i a) where
  gtoExpr (K1 x) = toExpr x

instance (Targetable a) => GQuery (K1 i a) where
  gquery p d t = do 
    let p' = reproxy p :: Proxy a
    ty <- gets makingTy
    depth <- asks depth
    sc <- asks scDepth
    let d' = if getType p' == ty || sc
                then d
                else depth
    query p' d' t

instance Targetable a => GDecodeFields (K1 i a) where
  gdecodeFields (v:vs) = do
    x <- decode v undefined
    return (vs, K1 x)

instance Targetable a => GCheckFields (K1 i a) where
  gcheckFields (K1 x) ((f,t):ts) = do
    (b, v) <- check x t
    return (b, [v], subst (mkSubst [(f, v)]) ts)

qualify :: String -> String -> String
qualify m x = m ++ ('.':x)
{-# INLINE qualify #-}

qualifiedDatatypeName :: Datatype d => D1 d f a -> Symbol
qualifiedDatatypeName d = symbol $ qualify m (datatypeName d)
  where m = GHC.Generics.moduleName d
{-# INLINE qualifiedDatatypeName #-}

--------------------------------------------------------------------------------
--- Sums
--------------------------------------------------------------------------------
class GToExprCtor f where
  gtoExprCtor   :: f a -> Expr

class GQueryCtors f where
  gqueryCtors :: Proxy (f a) -> Int -> SpecType -> Gen [(Expr, Expr)]

reproxyLeft :: Proxy ((c (f :: * -> *) (g :: * -> *)) a) -> Proxy (f a)
reproxyLeft = reproxy

reproxyRight :: Proxy ((c (f :: * -> *) (g :: * -> *)) a) -> Proxy (g a)
reproxyRight = reproxy

instance (GToExprCtor f, GToExprCtor g) => GToExprCtor (f :+: g) where
  gtoExprCtor (L1 x) = gtoExprCtor x
  gtoExprCtor (R1 x) = gtoExprCtor x

instance (GQueryCtors f, GQueryCtors g) => GQueryCtors (f :+: g) where
  gqueryCtors p d t = do 
    xs <- gqueryCtors (reproxyLeft p) d t
    ys <- gqueryCtors (reproxyRight p) d t
    return $! xs++ys

instance (GDecode f, GDecode g) => GDecode (f :+: g) where
  gdecode c vs =  L1 <$> gdecode c vs
              <|> R1 <$> gdecode c vs

instance (GCheck f, GCheck g) => GCheck (f :+: g) where
  gcheck (L1 x) t = gcheck x t
  gcheck (R1 x) t = gcheck x t


instance (Constructor c, GToExprFields f) => GToExprCtor (C1 c f) where
  gtoExprCtor c@(M1 x)  = app (symbol $ conName c) (gtoExprFields x)

instance (Constructor c, GRecursive f, GQueryFields f) => GQueryCtors (C1 c f) where
  gqueryCtors p d t | d <= 0
    = do ty <- gets makingTy
         if gisRecursive p ty
           then return []
           else pure <$> gqueryCtor p 0 t
  gqueryCtors p d t = pure <$> gqueryCtor p d t

instance (Constructor c, GDecodeFields f) => GDecode (C1 c f) where
  gdecode c vs
    | c == symbol (conName (undefined :: C1 c f a))
    = M1 . snd <$> gdecodeFields vs
    | otherwise
    = empty

instance (Constructor c, GCheckFields f) => GCheck (C1 c f) where
  gcheck (M1 x) t = do
    mod <- symbolString <$> gets modName
    let cn = symbol $ qualify mod (conName (undefined :: C1 c f a))
    ts <- unfold cn t
    (b, vs, _) <- gcheckFields x ts
    let v = app cn vs
    b'  <- eval v (toReft $ rt_reft t)
    return (b && b', v)

gisRecursive :: (Constructor c, GRecursive f)
             => Proxy (C1 c f a) -> Sort -> Bool
gisRecursive (p :: Proxy (C1 c f a)) t
  = t `elem` gconArgTys (reproxyGElem p)

gqueryCtor :: (Constructor c, GQueryFields f)
           => Proxy (C1 c f a) -> Int -> SpecType -> Gen (Expr, Expr)
gqueryCtor (p :: Proxy (C1 c f a)) d t
  = guarded cn $ do
      mod <- symbolString <$> gets modName
      ts  <- unfold (symbol $ qualify mod cn) t
      xs  <- gqueryFields (reproxyGElem p) d ts
      apply (symbol $ qualify mod cn) xs
  where
    cn = conName (undefined :: C1 c f a)

--------------------------------------------------------------------------------
--- Products
--------------------------------------------------------------------------------
class GToExprFields f where
  gtoExprFields :: f a -> [Expr]

class GRecursive f where
  gconArgTys  :: Proxy (f a) -> [Sort]

class GQueryFields f where
  gqueryFields  :: Proxy (f a) -> Int -> [(Symbol,SpecType)] -> Gen [Expr]

class GDecodeFields f where
  gdecodeFields :: [Symbol] -> Gen ([Symbol], f a)

class GCheckFields f where
  gcheckFields :: f a -> [(Symbol, SpecType)]
               -> Gen (Bool, [Expr], [(Symbol, SpecType)])


instance (GToExprFields f, GToExprFields g) => GToExprFields (f :*: g) where
  gtoExprFields (f :*: g) = gtoExprFields f ++ gtoExprFields g

instance (GRecursive f, GRecursive g) => GRecursive (f :*: g) where
  gconArgTys p = gconArgTys (reproxyLeft p) ++ gconArgTys (reproxyRight p)

instance (GQueryFields f, GQueryFields g) => GQueryFields (f :*: g) where
  gqueryFields p d ts = do 
    xs <- gqueryFields (reproxyLeft p) d ts
    let su = mkSubst $ zipWith (\x t -> (fst t, x)) xs ts
    let ts' = drop (length xs) ts
    ys <- gqueryFields (reproxyRight p) d (map (second (subst su)) ts')
    return $ xs ++ ys

instance (GDecodeFields f, GDecodeFields g) => GDecodeFields (f :*: g) where
  gdecodeFields vs = do
    (vs', ls)  <- gdecodeFields vs
    (vs'', rs) <- gdecodeFields vs'
    return (vs'', ls :*: rs)

instance (GCheckFields f, GCheckFields g) => GCheckFields (f :*: g) where
  gcheckFields (f :*: g) ts = do
    (bl,fs,ts')  <- gcheckFields f ts
    (br,gs,ts'') <- gcheckFields g ts'
    return (bl && br, fs ++ gs, ts'')


instance (GToExpr f) => GToExprFields (S1 c f) where
  gtoExprFields (M1 x)     = [gtoExpr x]

instance Targetable a => GRecursive (S1 c (K1 i a)) where
  gconArgTys _ = [getType (Proxy :: Proxy a)]

instance (GQuery f) => GQueryFields (S1 c f) where
  gqueryFields p d (t:_) = sequence [var <$> gquery (reproxyGElem p) (d-1) (snd t)]

instance GDecodeFields f => GDecodeFields (S1 c f) where
  gdecodeFields vs = do
    (vs', x) <- gdecodeFields vs
    return (vs', M1 x)

instance (GCheckFields f) => GCheckFields (S1 c f) where
  gcheckFields (M1 x) ts = gcheckFields x ts

instance GToExprFields U1 where
  gtoExprFields _ = []

instance GRecursive U1 where
  gconArgTys _    = []

instance GQueryFields U1 where
  gqueryFields _ _ _ = return []

instance GDecodeFields U1 where
  gdecodeFields vs = return (vs, U1)

instance GCheckFields U1 where
  gcheckFields _ ts = return (True, [], ts)
