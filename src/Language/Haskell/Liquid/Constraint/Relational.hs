{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeSynonymInstances       #-}

-- | This module defines the representation of Subtyping and WF Constraints,
--   and the code for syntax-directed constraint generation.

module Language.Haskell.Liquid.Constraint.Relational (consAssmRel, consRelTop) where

#if !MIN_VERSION_base(4,14,0)
import           Control.Monad.Fail
#endif

import           Control.Monad.State
import           Data.Bifunctor                                 ( Bifunctor(bimap) )
import qualified Data.HashMap.Strict                            as M
import qualified Data.List                                      as L
import qualified Data.Maybe                                     as MB
import           Data.String                                    ( IsString(..) )
import qualified Debug.Trace                                    as D
import           Language.Fixpoint.Misc
import qualified Language.Fixpoint.Types                        as F
import qualified Language.Fixpoint.Types.Names                  as F
import qualified Language.Fixpoint.Types.Visitor                as F
import           Language.Haskell.Liquid.Bare.DataType          (makeDataConChecker)
import           Language.Haskell.Liquid.Constraint.Constraint
import           Language.Haskell.Liquid.Constraint.Env
import           Language.Haskell.Liquid.Constraint.Fresh
import           Language.Haskell.Liquid.Constraint.Init
import           Language.Haskell.Liquid.Constraint.Monad
import           Language.Haskell.Liquid.Constraint.Split
import           Language.Haskell.Liquid.Constraint.Types
import           Language.Haskell.Liquid.GHC.API                ( Alt(..)
                                                                , AltCon(..) 
                                                                , Bind(..)
                                                                , CoreBind(..)
                                                                , CoreBndr(..)
                                                                , CoreExpr(..)
                                                                , DataCon(..)
                                                                , Expr(..)
                                                                , Type(..)
                                                                , TyVar(..)
                                                                , Var(..))
import qualified Language.Haskell.Liquid.GHC.API                as Ghc
import qualified Language.Haskell.Liquid.GHC.Misc               as GM
import           Language.Haskell.Liquid.GHC.Play               (isHoleVar, Subable(sub, subTy))
import qualified Language.Haskell.Liquid.GHC.Resugar            as Rs
import qualified Language.Haskell.Liquid.GHC.SpanStack          as Sp
import           Language.Haskell.Liquid.GHC.TypeRep            ()
import           Language.Haskell.Liquid.Misc
import           Language.Haskell.Liquid.Transforms.CoreToLogic (weakenResult)
import           Language.Haskell.Liquid.Transforms.Rec
import           Language.Haskell.Liquid.Types.Dictionaries
import           Language.Haskell.Liquid.Types                  hiding (Def,
                                                                 Loc, binds,
                                                                 loc)
import           System.Console.CmdArgs.Verbosity               (whenLoud)
import           System.IO.Unsafe                               (unsafePerformIO)
import           Text.PrettyPrint.HughesPJ                      hiding ( (<>) )

data RelPred
  = RelPred { fun1 :: Var
            , fun2 :: Var
            , args1 :: [F.Symbol]
            , args2 :: [F.Symbol]
            , prop :: F.Expr
            } deriving Show


type PrEnv = [RelPred]
type RelAlt = (AltCon, [Var], [Var], CoreExpr, CoreExpr)

consAssmRel :: Config -> TargetInfo -> CGEnv -> PrEnv -> (Var, Var, LocSpecType, LocSpecType, F.Expr, F.Expr) -> CG PrEnv
consAssmRel _ ti γ ψ (x, y, t, s, _, p) = traceChk "Assm" x y t s p $ do
  traceWhenLoud ("ASSUME " ++ F.showpp (p', p)) $ subUnarySig γ' x t'
  subUnarySig γ' y s'
  return $ RelPred x' y' vs us p' : RelPred y' x' us vs p' : ψ
  where
    γ' = γ `setLocation` Sp.Span (GM.fSrcSpan (F.loc t))
    (x', y') = mkRelCopies x y
    t' = val t
    s' = val s
    (vs, _) = vargs t'
    (us, _) = vargs s'
    p' = L.foldl (\p (v, u) -> unapplyRelArgs v u p) p (zip vs us)

consRelTop :: Config -> TargetInfo -> CGEnv -> PrEnv -> (Var, Var, LocSpecType, LocSpecType, F.Expr, F.Expr) -> CG PrEnv
consRelTop _ ti γ ψ (x, y, t, s, a, p) = traceChk "Init" e d t s p $ do
  subUnarySig γ' x t'
  subUnarySig γ' y s'
  consRelCheckBind γ' ψ e d t' s' a p
  where
    γ' = γ `setLocation` Sp.Span (GM.fSrcSpan (F.loc t))
    cbs = giCbs $ giSrc ti
    e = lookupBind x cbs
    d = lookupBind y cbs
    t' = val t 
    s' = val s

--------------------------------------------------------------
-- Core Checking Rules ---------------------------------------
--------------------------------------------------------------

resL, resR :: F.Symbol
resL = fromString "r1"
resR = fromString "r2"

relSuffixL, relSuffixR :: String
relSuffixL = "l"
relSuffixR = "r"

-- recursion rule
consRelCheckBind :: CGEnv -> PrEnv -> CoreBind -> CoreBind -> SpecType -> SpecType -> F.Expr -> F.Expr -> CG PrEnv
consRelCheckBind γ ψ b1@(NonRec _ e1) b2@(NonRec _ e2) t1 t2 a p 
  | Nothing <- args e1 e2 t1 t2 p =
  traceChk "Bind NonRec" b1 b2 t1 t2 p $ do
    consRelCheck γ ψ e1 e2 t1 t2 p
    return ψ
consRelCheckBind γ ψ (NonRec x1 e1) b2 t1 t2 a p =
  consRelCheckBind γ ψ (Rec [(x1, e1)]) b2 t1 t2 a p
consRelCheckBind γ ψ b1 (NonRec x2 e2) t1 t2 a p =
  consRelCheckBind γ ψ b1 (Rec [(x2, e2)]) t1 t2 a p
consRelCheckBind γ ψ b1@(Rec [(f1, e1)]) b2@(Rec [(f2, e2)]) t1 t2 a p
  | Just (xs1, xs2, vs1, vs2, ts1, ts2, qs) <- args e1 e2 t1 t2 p
  = traceChk "Bind Rec" b1 b2 t1 t2 p $ do
    forM_ (refts t1 ++ refts t2) (\r -> entlFunReft γ r "consRelCheckBind Rec")
    let xs' = zipWith mkRelCopies xs1 xs2
    let (xs1', xs2') = unzip xs'
    let (e1'', e2'') = L.foldl' subRel (e1', e2') (zip xs1 xs2)
    γ' <- γ += ("Bind Rec f1", F.symbol f1', t1) >>= (+= ("Bind Rec f2", F.symbol f2', t2))
    γ'' <- foldM (\γ (x, t) -> γ += ("Bind Rec x1", F.symbol x, t)) γ' (zip (xs1' ++ xs2') (ts1 ++ ts2))
    let vs2xs =  F.subst $ F.mkSubst $ zip (vs1 ++ vs2) $ map (F.EVar . F.symbol) (xs1' ++ xs2') 
    γ''' <- γ'' `addPreds` traceWhenLoud ("PRECONDITION " ++ F.showpp (vs2xs (F.PAnd qs)) ++ "\n" ++ 
                                          "ASSUMPTION " ++ F.showpp (vs2xs a)) 
                              [vs2xs (F.PAnd qs), vs2xs a]
    let p' = unapp p (zip vs1 vs2)
    let ψ' = RelPred f1' f2' vs1 vs2 p' : RelPred f2' f1' vs2 vs1 p' : ψ
    consRelCheck γ''' ψ' (xbody e1'') (xbody e2'') (vs2xs $ ret t1) (vs2xs $ ret t2) (vs2xs $ concl p')
    return ψ'
  where 
    (f1', f2') = mkRelCopies f1 f2
    (e1', e2') = subRelCopies e1 f1 e2 f2
    unapp = L.foldl (\p (v1, v2) -> unapplyRelArgs v1 v2 p)
    subRel (e1, e2) (x1, x2) = subRelCopies e1 x1 e2 x2
consRelCheckBind _ _ b1@(Rec [(f1, e1)]) b2@(Rec [(f2, e2)]) t1 t2 _ p
  = F.panic $ "consRelCheckBind Rec: exprs, types, and pred should have same number of args " ++ 
    show (args e1 e2 t1 t2 p)
consRelCheckBind _ _ b1@(Rec _) b2@(Rec _) _ _ _ _
  = F.panic $ "consRelCheckBind Rec: multiple binders are not supported " ++ F.showpp (b1, b2)

-- Definition of CoreExpr: https://hackage.haskell.org/package/ghc-8.10.1/docs/CoreSyn.html
consRelCheck :: CGEnv -> PrEnv -> CoreExpr -> CoreExpr -> 
  SpecType -> SpecType -> F.Expr -> CG ()
consRelCheck γ ψ (Tick _ e) d t s p =
  {- traceChk "Left Tick" e d t s p $ -} consRelCheck γ ψ e d t s p

consRelCheck γ ψ e (Tick _ d) t s p =
  {- traceChk "Right Tick" e d t s p $ -} consRelCheck γ ψ e d t s p

consRelCheck γ ψ l1@(Lam α1 e1) e2 rt1@(RAllT s1 t1 r1) t2 p 
  | Ghc.isTyVar α1
  = traceChk "Lam Type L" l1 e2 rt1 t2 p $ do
    entlFunReft γ r1 "consRelCheck Lam Type"
    γ'  <- γ `extendWithTyVar` α1
    consRelCheck γ' ψ e1 e2 (sub (s1, α1) t1) t2 p
  where sub (s, α) = subsTyVar_meet' (ty_var_value s, rVar α)

consRelCheck γ ψ e1 l2@(Lam α2 e2) t1 rt2@(RAllT s2 t2 r2) p 
  | Ghc.isTyVar α2
  = traceChk "Lam Type" e1 l2 t1 rt2 p $ do
    entlFunReft γ r2 "consRelCheck Lam Type"
    γ'  <- γ `extendWithTyVar` α2
    consRelCheck γ' ψ e1 e2 t1 (sub (s2, α2) t2) p
  where sub (s, α) = subsTyVar_meet' (ty_var_value s, rVar α)

consRelCheck γ ψ l1@(Lam α1 e1) l2@(Lam α2 e2) rt1@(RAllT s1 t1 r1) rt2@(RAllT s2 t2 r2) p 
  | Ghc.isTyVar α1 && Ghc.isTyVar α2
  = traceChk "Lam Type" l1 l2 rt1 rt2 p $ do
    entlFunRefts γ r1 r2 "consRelCheck Lam Type"
    γ'  <- γ `extendWithTyVar` α1
    γ'' <- γ' `extendWithTyVar` α2
    consRelCheck γ'' ψ e1 e2 (sub (s1, α1) t1) (sub (s2, α2) t2) p
  where sub (s, α) = subsTyVar_meet' (ty_var_value s, rVar α)

consRelCheck γ ψ l1@(Lam x1 e1) l2@(Lam x2 e2) rt1@(RFun v1 s1 t1 r1) rt2@(RFun v2 s2 t2 r2) pr@(F.PImp q p)
  = traceChk "Lam Expr" l1 l2 rt1 rt2 pr $ do
    entlFunRefts γ r1 r2 "consRelCheck Lam Expr"
    let (evar1, evar2) = mkRelCopies x1 x2
    let (e1', e2')     = subRelCopies e1 x1 e2 x2
    let (pvar1, pvar2) = (F.symbol evar1, F.symbol evar2)
    let subst = F.subst $ F.mkSubst [(v1, F.EVar pvar1), (v2, F.EVar pvar2)]
    γ'  <- γ += ("consRelCheck Lam L", pvar1, subst s1)
    γ'' <- γ' += ("consRelCheck Lam R", pvar2, subst s2)
    let p'    = unapplyRelArgs v1 v2 p
    γ''' <- γ'' `addPred` traceWhenLoud ("PRECONDITION " ++ F.showpp (subst q)) subst q
    consRelCheck γ''' ψ e1' e2' (subst t1) (subst t2) (subst p')

consRelCheck γ ψ l1@(Let (NonRec x1 d1) e1) l2@(Let (NonRec x2 d2) e2) t1 t2 p
  = traceChk "Let" l1 l2 t1 t2 p $ do
    (s1, s2, qs) <- consRelSynth γ ψ d1 d2
    let (evar1, evar2) = mkRelCopies x1 x2
    let (e1', e2')     = subRelCopies e1 x1 e2 x2
    γ'  <- γ += ("consRelCheck Let L", F.symbol evar1, s1)
    γ'' <- γ' += ("consRelCheck Let R", F.symbol evar2, s2)
    let rs2xs = F.mkSubst [(resL, F.EVar $ F.symbol evar1), (resR, F.EVar $ F.symbol evar2)]
    γ''' <- γ'' `addPreds` map (F.subst rs2xs) qs
    consRelCheck γ''' ψ e1' e2' t1 t2 p

consRelCheck γ ψ l1@(Let (Rec []) e1) l2@(Let (Rec []) e2) t1 t2 p 
  = traceChk "Let Rec Nil" l1 l2 t1 t2 p $ do
    consRelCheck γ ψ e1 e2 t1 t2 p

consRelCheck γ ψ l1@(Let (Rec ((x1, d1):bs1)) e1) l2@(Let (Rec ((x2, d2):bs2)) e2) t1 t2 p
  = traceChk "Let Rec Cons" l1 l2 t1 t2 p $ do
    (s1, s2, qs) <- consRelSynth γ ψ d1 d2
    let (evar1, evar2) = mkRelCopies x1 x2
    let (e1', e2')     = subRelCopies e1 x1 e2 x2
    γ'  <- γ += ("consRelCheck Let L", F.symbol evar1, s1)
    γ'' <- γ' += ("consRelCheck Let R", F.symbol evar2, s2)
    γ''' <- γ'' `addPreds` qs
    consRelCheck γ''' ψ (Let (Rec bs1) e1') (Let (Rec bs2) e2') t1 t2 p

{- consRelCheck γ ψ c1@(Case e1 x1 _ alts1) c2@(Case e2 x2 _ alts2) t1 t2 p 
  | Just alts <- unifyAlts x1 x2 alts1 alts2 = 
  traceChk "Case Sync " c1 c2 t1 t2 p $ do
  (s1, s2, _) <- consRelSynth γ ψ e1 e2
  γ' <- γ += ("consRelCheck Case Sync L", x1', s1)
  γ'' <- γ' += ("consRelCheck Case Sync R", x2', s2)
  forM_ (ctors alts) $ consSameCtors γ'' ψ x1' x2' s1 s2 (nonDefaults alts)
  forM_ alts $ consRelCheckAltSync γ'' ψ t1 t2 p x1' x2' s1 s2
  where
    nonDefaults = filter (/= DEFAULT) . ctors
    ctors = map (\(c, _, _, _, _) -> c)
    (evar1, evar2) = mkRelCopies x1 x2
    x1' = F.symbol evar1
    x2' = F.symbol evar2 -}
  
consRelCheck γ ψ c1@(Case e1 x1 _ alts1) e2 t1 t2 p =
  traceChk "Case Async L" c1 e2 t1 t2 p $ do
    s1 <- consUnarySynth γ e1
    γ' <- γ += ("consRelCheck Case Async L", x1', s1)
    forM_ alts1 $ consRelCheckAltAsyncL γ' ψ t1 t2 p x1' s1 e2
  where
    x1' = F.symbol $ mkCopyWithSuffix relSuffixL x1

consRelCheck γ ψ e1 c2@(Case e2 x2 _ alts2) t1 t2 p =
  traceChk "Case Async R" e1 c2 t1 t2 p $ do
    s2 <- consUnarySynth γ e2
    γ' <- γ += ("consRelCheck Case Async R", x2', s2)
    forM_ alts2 $ consRelCheckAltAsyncR γ' ψ t1 t2 p e1 x2' s2
  where
    x2' = F.symbol $ mkCopyWithSuffix relSuffixR x2

consRelCheck γ ψ e d t1 t2 p = 
  traceChk "Synth" e d t1 t2 p $ do
  (s1, s2, qs) <- consRelSynth γ ψ e d
  let psubst = F.substf (matchFunArgs t1 s1) . F.substf (matchFunArgs t2 s2)
  consRelSub γ s1 s2 (F.PAnd qs) (psubst p)
  addC (SubC γ s1 t1) ("consRelCheck (Synth): s1 = " ++ F.showpp s1 ++ " t1 = " ++ F.showpp t1)
  addC (SubC γ s2 t2) ("consRelCheck (Synth): s2 = " ++ F.showpp s2 ++ " t2 = " ++ F.showpp t2)

consSameCtors :: CGEnv -> PrEnv -> F.Symbol -> F.Symbol -> SpecType -> SpecType -> [AltCon] -> AltCon  -> CG ()
consSameCtors γ ψ x1 x2 s1 s2 alts (DataAlt c) | isBoolDataCon c
  = entl γ (F.PIff (F.EVar x1) (F.EVar x2)) "consSameCtors DataAlt Bool"
consSameCtors γ ψ x1 x2 s1 s2 alts (DataAlt c)
  = entl γ (F.PIff (isCtor c $ F.EVar x1) (isCtor c $ F.EVar x2)) "consSameCtors DataAlt"
consSameCtors γ ψ x1 x2 _ _ _ (LitAlt l)
  = F.panic "consSameCtors undefined for literals"
consSameCtors _ _ _ _ _ _ alts DEFAULT
  = F.panic "consSameCtors undefined for default"

consExtAltEnv :: CGEnv -> F.Symbol -> SpecType -> AltCon -> [Var] -> CoreExpr -> String -> CG (CGEnv, CoreExpr)
consExtAltEnv γ x s c bs e suf = do 
  ct <- ctorTy γ c s
  unapply γ x s bs ct e suf

consRelCheckAltAsyncL :: CGEnv -> PrEnv -> SpecType -> SpecType -> F.Expr -> 
  F.Symbol -> SpecType -> CoreExpr -> Alt CoreBndr -> CG ()
consRelCheckAltAsyncL γ ψ t1 t2 p x1 s1 e2 (c, bs1, e1) = do
  (γ', e1') <- consExtAltEnv γ x1 s1 c bs1 e1 relSuffixL
  consRelCheck γ' ψ e1' e2 t1 t2 p

consRelCheckAltAsyncR :: CGEnv -> PrEnv -> SpecType -> SpecType -> F.Expr -> 
  CoreExpr -> F.Symbol -> SpecType -> Alt CoreBndr -> CG ()
consRelCheckAltAsyncR γ ψ t1 t2 p e1 x2 s2 (c, bs2, e2) = do
  (γ', e2') <- consExtAltEnv γ x2 s2 c bs2 e2 relSuffixR
  consRelCheck γ' ψ e1 e2' t1 t2 p

consRelCheckAltSync :: CGEnv -> PrEnv -> SpecType -> SpecType -> F.Expr -> 
  F.Symbol -> F.Symbol -> SpecType -> SpecType -> RelAlt -> CG ()
consRelCheckAltSync γ ψ t1 t2 p x1 x2 s1 s2 (c, bs1, bs2, e1, e2) = do
  (γ', e1') <- consExtAltEnv γ x1 s1 c bs1 e1 relSuffixL
  (γ'', e2') <- consExtAltEnv γ' x2 s2 c bs2 e2 relSuffixR
  consRelCheck γ'' ψ e1' e2' t1 t2 p

ctorTy :: CGEnv -> AltCon -> SpecType -> CG SpecType
ctorTy γ (DataAlt c) (RApp _ ts _ _) 
  | Just ct <- mbct = refreshTy $ ct `instantiateTys` ts
  | Nothing <- mbct = F.panic $ "ctorTy: data constructor out of scope" ++ F.showpp c
  where mbct = γ ?= F.symbol (Ghc.dataConWorkId c)
ctorTy _ (DataAlt _) t =
  F.panic $ "ctorTy: type " ++ F.showpp t ++ " doesn't have top-level data constructor"
ctorTy _ (LitAlt c) _ = return $ uTop <$> literalFRefType c
ctorTy _ DEFAULT t = return t

unapply :: CGEnv -> F.Symbol -> SpecType -> [Var] -> SpecType -> CoreExpr -> String -> CG (CGEnv, CoreExpr)
unapply γ y yt (z : zs) (RFun x s t _) e suffix = do
  γ' <- γ += ("unapply arg", evar, s)
  unapply γ' y yt zs (t `F.subst1` (x, F.EVar evar)) e' suffix
  where 
    z' = mkCopyWithSuffix suffix z
    evar = F.symbol z'
    e' = subVarAndTy z z' e
unapply _ _ _ (_ : _) t _ _ = F.panic $ "can't unapply type " ++ F.showpp t
unapply γ y yt [] t e _ = do
  let yt' = t `F.meet` yt
  γ' <- γ += ("unapply res", y, yt')
  return $ traceWhenLoud ("SCRUTINEE " ++ F.showpp (y, yt')) (γ', e)

instantiateTys :: SpecType -> [SpecType] -> SpecType
instantiateTys = L.foldl' go
 where
  go (RAllT α tbody _) t = subsTyVar_meet' (ty_var_value α, t) tbody
  go tbody             t = 
    F.panic $ "instantiateTys: non-polymorphic type " ++ F.showpp tbody ++ " to instantiate with " ++ F.showpp t 

--------------------------------------------------------------
-- Core Synthesis Rules --------------------------------------
--------------------------------------------------------------

consRelSynth :: CGEnv -> PrEnv -> CoreExpr -> CoreExpr -> CG (SpecType, SpecType, [F.Expr])
consRelSynth γ ψ (Tick _ e) d =
  {- traceSyn "Left Tick" e d -} consRelSynth γ ψ e d

consRelSynth γ ψ e (Tick _ d) =
  {- traceSyn "Right Tick" e d -} consRelSynth γ ψ e d

consRelSynth γ ψ a1@(App e1 d1) e2 | Type t1 <- GM.unTickExpr d1 =
  traceSyn "App Ty L" a1 e2 $ do
    (ft1', t2, ps) <- consRelSynth γ ψ e1 e2
    let (α1, ft1, r1) = unRAllT ft1' "consRelSynth App Ty L"
    t1' <- trueTy t1
    return (subsTyVar_meet' (ty_var_value α1, t1') ft1, t2, ps)

consRelSynth γ ψ e1 a2@(App e2 d2) | Type t2 <- GM.unTickExpr d2 =
  traceSyn "App Ty R" e1 a2 $ do
    (t1, ft2', ps) <- consRelSynth γ ψ e1 e2
    let (α2, ft2, r2) = unRAllT ft2' "consRelSynth App Ty R"
    t2' <- trueTy t2
    return (t1, subsTyVar_meet' (ty_var_value α2, t2') ft2, ps)

consRelSynth γ ψ a1@(App e1 d1) a2@(App e2 d2) = traceSyn "App Exp Exp" a1 a2 $ do
  (ft1, ft2, fps) <- consRelSynth γ ψ e1 e2
  (t1, t2, ps) <- consRelSynthApp γ ψ ft1 ft2 fps (GM.unTickExpr d1) (GM.unTickExpr d2)
  return (t1, t2, instantiateApp a1 a2 ψ ++ ps)

consRelSynth γ _ e d = traceSyn "Unary" e d $ do
  t <- consUnarySynth γ e >>= refreshTy
  s <- consUnarySynth γ d >>= refreshTy
  return (t, s, [wfTruth t s])

consRelSynthApp :: CGEnv -> PrEnv -> SpecType -> SpecType -> 
  [F.Expr] -> CoreExpr -> CoreExpr -> CG (SpecType, SpecType, [F.Expr])
consRelSynthApp γ _ (RFun v1 s1 t1 r1) (RFun v2 s2 t2 r2) ps d1@(Var x1) d2@(Var x2)
  = do
    entlFunRefts γ r1 r2 "consRelSynthApp"
    -- let qsubst = F.subst $ F.mkSubst [(v1, F.EVar resL), (v2, F.EVar resR)]
    -- consRelCheck γ ψ d1 d2 s1 s2 (qsubst q)
    consUnaryCheck γ d1 s1
    consUnaryCheck γ d2 s2
    let subst =
          F.subst $ F.mkSubst
            [(v1, F.EVar $ F.symbol x1), (v2, F.EVar $ F.symbol x2)]
    return (subst t1, subst t2, map (subst . unapplyRelArgs v1 v2) ps)
consRelSynthApp _ _ RFun{} RFun{} _ d1 d2 = 
  F.panic $ "consRelSynthApp: expected application to variables, got" ++ F.showpp (d1, d2)
consRelSynthApp _ _ t1 t2 p d1 d2 = 
  F.panic $ "consRelSynthApp: malformed function types or predicate for arguments " ++ F.showpp (t1, t2, p, d1, d2)

--------------------------------------------------------------
-- Unary Rules -----------------------------------------------
--------------------------------------------------------------

symbolType :: CGEnv -> Var -> String -> SpecType
symbolType γ x msg
  | Just t <- γ ?= F.symbol x = t
  | otherwise = F.panic $ msg ++ " " ++ F.showpp x ++ " not in scope " ++ F.showpp γ 

consUnarySynth :: CGEnv -> CoreExpr -> CG SpecType
consUnarySynth γ (Tick _ e) = consUnarySynth γ e
consUnarySynth γ (Var x) = return $ traceWhenLoud ("SELFIFICATION " ++ F.showpp (x, t, selfify t x)) selfify t x
  where t = symbolType γ x "consUnarySynth (Var)"
consUnarySynth _ (Lit c) = return $ uRType $ literalFRefType c
consUnarySynth γ e@(Let _ _) = 
  traceUSyn "Let" e $ do
  t   <- freshTy_type LetE e $ Ghc.exprType e
  addW $ WfC γ t
  consUnaryCheck γ e t
  return t
consUnarySynth γ (App e d) = do
  et <- consUnarySynth γ e
  consUnarySynthApp γ et (GM.unTickExpr d)
consUnarySynth γ (Lam α e) | Ghc.isTyVar α = do
  γ' <- γ `extendWithTyVar` α
  t' <- consUnarySynth γ' e
  return $ RAllT (makeRTVar $ rTyVar α) t' mempty
consUnarySynth γ e@(Lam x d)  = do
  let Ghc.FunTy { ft_arg = s' } = checkFun e $ Ghc.exprType e
  s  <- freshTy_type LamE (Var x) s'
  γ' <- γ += ("consUnarySynth (Lam)", F.symbol x, s)
  t  <- consUnarySynth γ' d
  addW $ WfC γ t
  return $ RFun (F.symbol x) s t mempty
consUnarySynth γ e@(Case _ _ _ alts) = do
  t   <- freshTy_type (caseKVKind alts) e $ Ghc.exprType e
  addW $ WfC γ t
  -- consUnaryCheck γ e t
  return t
consUnarySynth _ e@(Cast _ _) = F.panic $ "consUnarySynth is undefined for Cast " ++ F.showpp e
consUnarySynth _ e@(Type _) = F.panic $ "consUnarySynth is undefined for Type " ++ F.showpp e
consUnarySynth _ e@(Coercion _) = F.panic $ "consUnarySynth is undefined for Coercion " ++ F.showpp e

caseKVKind :: [Alt Var] -> KVKind
caseKVKind [(DataAlt _, _, Var _)] = ProjectE
caseKVKind cs                      = CaseE (length cs)

checkFun :: CoreExpr -> Type -> Type 
checkFun _ t@Ghc.FunTy{} = t 
checkFun e t = F.panic $ "FunTy was expected but got " ++ F.showpp t ++ "\t for expression" ++ F.showpp e

base :: SpecType -> Bool
base RApp{} = True
base RVar{} = True
base _      = False

selfifyExpr :: SpecType -> F.Expr -> Maybe SpecType
selfifyExpr (RFun v s t r) f = (\t -> RFun v s t r) <$> selfifyExpr t (F.EApp f (F.EVar v))
-- selfifyExpr (RAllT α t r) f = (\t -> RAllT α t r) <$> selfifyExpr t f
-- selfifyExpr (RAllT α t r) f = (\t -> RAllT α t r) <$> selfifyExpr t (F.ETApp f (F.FVar 0))
selfifyExpr t e | base t = Just $ t `strengthen` eq e
  where eq = uTop . F.exprReft
selfifyExpr _ _ = Nothing

selfify :: F.Symbolic a => SpecType -> a -> SpecType
selfify t x | base t = t `strengthen` eq x  
  where eq = uTop . F.symbolReft . F.symbol
selfify t e | Just t' <- selfifyExpr t (F.EVar $ F.symbol e) = t'
selfify t _ = t

consUnarySynthApp :: CGEnv -> SpecType -> CoreExpr -> CG SpecType
consUnarySynthApp γ (RFun x s t _) d@(Var y) = do
  consUnaryCheck γ d s
  return $ t `F.subst1` (x, F.EVar $ F.symbol y)
consUnarySynthApp _ (RAllT α t _) (Type s) = do
    s' <- trueTy s
    return $ subsTyVar_meet' (ty_var_value α, s') t
consUnarySynthApp γ RFun{} d = 
  F.panic $ "consUnarySynthApp expected Var as a funciton arg, got " ++ F.showpp d
consUnarySynthApp _ ft d = 
  F.panic $ "consUnarySynthApp malformed function type " ++ F.showpp ft ++
            " for argument " ++ F.showpp d  

consUnaryCheck :: CGEnv -> CoreExpr -> SpecType -> CG ()
consUnaryCheck γ (Let (NonRec x d) e) t = do
  s <- consUnarySynth γ d
  γ' <- γ += ("consUnaryCheck Let", F.symbol x, s)
  consUnaryCheck γ' e t
consUnaryCheck γ e t = do
  s <- consUnarySynth γ e
  addC (SubC γ s t) ("consUnaryCheck (Synth): s = " ++ F.showpp s ++ " t = " ++ F.showpp t)

--------------------------------------------------------------
-- Predicate Subtyping  --------------------------------------
--------------------------------------------------------------

consRelSub :: CGEnv -> SpecType -> SpecType -> F.Expr -> F.Expr -> CG ()
consRelSub γ f1@(RFun x1 s1 e1 _) f2 p1 p2 =
  traceSub "fun" f1 f2 p1 p2 $ do
    γ' <- γ += ("consRelSub RFun L", F.symbol x1, s1)
    let psubst = unapplyArg resL x1
    consRelSub γ' e1 f2 (psubst p1) (psubst p2)
consRelSub γ f1 f2@(RFun x2 s2 e2 _) p1 p2 = 
  traceSub "fun" f1 f2 p1 p2 $ do
    γ' <- γ += ("consRelSub RFun R", F.symbol x2, s2)
    let psubst = unapplyArg resR x2
    consRelSub γ' f1 e2 (psubst p1) (psubst p2)
consRelSub γ t1 t2 p1 p2 | isBase t1 && isBase t2 = 
  traceSub "base" t1 t2 p1 p2 $ do
    rl <- fresh
    rr <- fresh
    γ' <- γ += ("consRelSub Base L", rl, t1) 
    γ'' <- γ' += ("consRelSub Base R", rr, t2)
    entl γ'' (F.subst (F.mkSubst [(resL, F.EVar rl), (resR, F.EVar rr)]) $ F.PImp p1 p2) "consRelSub Base"
consRelSub _ t1@(RHole _) t2@(RHole _) _ _ = F.panic $ "consRelSub is undefined for RHole " ++ show (t1, t2)
consRelSub _ t1@(RExprArg _) t2@(RExprArg _) _ _ = F.panic $ "consRelSub is undefined for RExprArg " ++ show (t1, t2)
consRelSub _ t1@REx {} t2@REx {} _ _ = F.panic $ "consRelSub is undefined for REx " ++ show (t1, t2)
consRelSub _ t1@RAllE {} t2@RAllE {} _ _ = F.panic $ "consRelSub is undefined for RAllE " ++ show (t1, t2)
consRelSub _ t1@RRTy {} t2@RRTy {} _ _ = F.panic $ "consRelSub is undefined for RRTy " ++ show (t1, t2)
consRelSub _ t1@RAllP {} t2@RAllP {} _ _ = F.panic $ "consRelSub is undefined for RAllP " ++ show (t1, t2)
consRelSub _ t1@RAllT {} t2@RAllT {} _ _ = F.panic $ "consRelSub is undefined for RAllT " ++ show (t1, t2)
consRelSub _ t1@RImpF {} t2@RImpF {} _ _ = F.panic $ "consRelSub is undefined for RImpF " ++ show (t1, t2)
consRelSub _ t1 t2 _ _ =  F.panic $ "consRelSub is undefined for different types " ++ show (t1, t2)

--------------------------------------------------------------
-- Predicate Well-Formedness ---------------------------------
--------------------------------------------------------------

wfTruth :: SpecType -> SpecType -> F.Expr
wfTruth (RAllT _ t1 _) t2 = wfTruth t1 t2
wfTruth t1 (RAllT _ t2 _) = wfTruth t1 t2
wfTruth (RFun _ _ t1 _) (RFun _ _ t2 _) = 
  F.PImp F.PTrue $ wfTruth t1 t2
wfTruth _ _ = F.PTrue

--------------------------------------------------------------
-- Helper Definitions ----------------------------------------
--------------------------------------------------------------

unRAllT :: SpecType -> String -> (RTVU RTyCon RTyVar, SpecType, RReft)
unRAllT (RAllT α2 ft2 r2) _ = (α2, ft2, r2)
unRAllT t msg = F.panic $ msg ++ ": expected RAllT, got: " ++ F.showpp t 

isCtor :: Ghc.DataCon -> F.Expr -> F.Expr
isCtor d = F.EApp (F.EVar $ makeDataConChecker d)

isAltCon :: AltCon -> F.Symbol -> F.Expr
isAltCon (DataAlt c) x | c == Ghc.trueDataCon  = F.EVar x
isAltCon (DataAlt c) x | c == Ghc.falseDataCon = F.PNot $ F.EVar x
isAltCon (DataAlt c) x                         = isCtor c (F.EVar x)
isAltCon _           _                         = F.PTrue

isBoolDataCon :: DataCon -> Bool
isBoolDataCon c = c == Ghc.trueDataCon || c == Ghc.falseDataCon

args :: CoreExpr -> CoreExpr -> SpecType -> SpecType -> F.Expr -> 
  Maybe ([Var], [Var], [F.Symbol], [F.Symbol], [SpecType], [SpecType], [F.Expr])
args e1 e2 t1 t2 ps
  | xs1 <- xargs e1, xs2 <- xargs e2, 
    (vs1, ts1) <- vargs t1, (vs2, ts2) <- vargs t2,
    qs  <- prems ps,
    all (length qs ==) [length xs1, length xs2, length vs1, length vs2, length ts1, length ts2]
  = Just (xs1, xs2, vs1, vs2, ts1, ts2, qs)
args e1 e2 t1 t2 ps = traceWhenLoud ("args guard" ++ F.showpp (xargs e1, xargs e2, vargs t1, vargs t2, prems ps)) Nothing

xargs :: CoreExpr -> [Var]
xargs (Tick _ e) = xargs e
xargs (Lam  x e) | Ghc.isTyVar x = xargs e
xargs (Lam  x e) = x : xargs e
xargs _          = []

xbody :: CoreExpr -> CoreExpr
xbody (Tick _ e) = xbody e
xbody (Lam  _ e) = xbody e
xbody e          = e

refts :: SpecType -> [RReft]
refts (RAllT _ t r ) = r : refts t
refts (RFun _ _ t r) = r : refts t
refts _              = []

vargs :: SpecType -> ([F.Symbol], [SpecType]) 
vargs (RAllT _ t _ ) = vargs t
vargs (RFun v s t _) = bimap (v :) (s :) $ vargs t
vargs _              = ([], [])

ret :: SpecType -> SpecType
ret (RAllT _ t _ ) = ret t
ret (RFun _ _ t _) = ret t
ret t              = t

prems :: F.Expr -> [F.Expr]
prems (F.PImp q p) = q : prems p
prems _            = []

concl :: F.Expr -> F.Expr
concl (F.PImp _ p) = concl p
concl p            = p

unpackApp :: CoreExpr -> Maybe [Var]
unpackApp = fmap reverse . unpack' . GM.unTickExpr
 where
  unpack' (Var f        ) = Just [f]
  unpack' (App e (Var x)) = (x :) <$> unpack' e
  unpack' _               = Nothing

instantiateApp :: CoreExpr -> CoreExpr -> PrEnv -> [F.Expr]
instantiateApp e1 e2 ψ
  = traceWhenLoud ("instantiateApp " ++ F.showpp e1 ++ " " ++ F.showpp e2 ++ " " ++ show ψ) concatMap (inst (unpackApp e1) (unpackApp e2)) ψ 
 where
  inst :: Maybe [Var] -> Maybe [Var] -> RelPred -> [F.Expr]
  inst (Just (f1:xs1)) (Just (f2:xs2)) qpr
    | traceWhenLoud ("INST GUARD" ++ F.showpp (fun1 qpr) ++ " == " ++ F.showpp f1) fun1 qpr == f1
    , traceWhenLoud ("INST GUARD" ++ F.showpp (fun2 qpr) ++ " == " ++ F.showpp f2) fun2 qpr == f2
    , traceWhenLoud ("INST GUARD" ++ F.showpp (args1 qpr) ++ " -> " ++ F.showpp xs1) length (args1 qpr) == length xs1
    , traceWhenLoud ("INST GUARD" ++ F.showpp (args2 qpr) ++ " -> " ++ F.showpp xs2) length (args2 qpr) == length xs2
    = let s = zip (args1 qpr ++ args2 qpr) (F.EVar . F.symbol <$> xs1 ++ xs2)
      in let sub = F.mkSubst s
        in let p = F.subst sub $ prop qpr
          in traceWhenLoud ("INSTANTIATION " ++ F.showpp (p, prop qpr) ++ " " ++ show s) [p]
  inst _ _ _ = []

extendWithTyVar :: CGEnv -> TyVar -> CG CGEnv
extendWithTyVar γ a
  | isValKind (Ghc.tyVarKind a) 
  = γ += ("extendWithTyVar", F.symbol a, kindToRType $ Ghc.tyVarKind a)
  | otherwise 
  = return γ

unifyAlts :: CoreBndr -> CoreBndr -> [Alt CoreBndr] -> [Alt CoreBndr] -> Maybe [RelAlt]
unifyAlts x1 x2 alts1 alts2 = mapM subRelCopiesAlts (zip alts1 alts2)
  where 
    subRelCopiesAlts ((a1, bs1, e1), (a2, bs2, e2)) 
      | a1 /= a2  = Nothing
      | otherwise = let (e1', e2') = L.foldl' sub (subRelCopies e1 x1 e2 x2) (zip bs1 bs2)
                     in Just (a1, mkLCopies bs1, mkRCopies bs2, e1', e2')
    sub (e1, e2) (x1, x2) = subRelCopies e1 x1 e2 x2

matchFunArgs :: SpecType -> SpecType -> F.Symbol -> F.Expr
matchFunArgs (RAllT _ t1 _) t2 x = matchFunArgs t1 t2 x
matchFunArgs t1 (RAllT _ t2 _) x = matchFunArgs t1 t2 x
matchFunArgs (RFun x1 _ t1 _) (RFun x2 _ t2 _) x = 
  if x == x1 then F.EVar x2 else matchFunArgs t1 t2 x
matchFunArgs t1 t2 x | isBase t1 && isBase t2 = F.EVar x
matchFunArgs t1 t2 _ = F.panic $ "matchFunArgs undefined for " ++ F.showpp (t1, t2)

entl :: CGEnv -> F.Expr -> String -> CG ()
entl γ p = addC (SubR γ ORel $ uReft (F.vv_, F.PIff (F.EVar F.vv_) p))

entlFunReft :: CGEnv -> RReft -> String -> CG ()
entlFunReft γ r msg = do
  entl γ (F.reftPred $ ur_reft r) $ "entlFunRefts " ++ msg

entlFunRefts :: CGEnv -> RReft -> RReft -> String -> CG ()
entlFunRefts γ r1 r2 msg = do
  entlFunReft γ r1 $ msg ++ " L"
  entlFunReft γ r2 $ msg ++ " R"

subRelCopies :: CoreExpr -> Var -> CoreExpr -> Var -> (CoreExpr, CoreExpr)
subRelCopies e1 x1 e2 x2 = (subVarAndTy x1 evar1 e1, subVarAndTy x2 evar2 e2)
  where (evar1, evar2) = mkRelCopies x1 x2

subVarAndTy :: Var -> Var -> CoreExpr -> CoreExpr
subVarAndTy x v = subTy (M.singleton x $ TyVarTy v) . sub (M.singleton x $ Var v)

mkRelCopies :: Var -> Var -> (Var, Var)
mkRelCopies x1 x2 = (mkCopyWithSuffix relSuffixL x1, mkCopyWithSuffix relSuffixR x2)

mkLCopies :: [Var] -> [Var]
mkLCopies = (mkCopyWithSuffix relSuffixL <$>)

mkRCopies :: [Var] -> [Var]
mkRCopies = (mkCopyWithSuffix relSuffixR <$>)

mkCopyWithName :: String -> Var -> Var
mkCopyWithName s v = 
  Ghc.setVarName v $ Ghc.mkSystemName (Ghc.getUnique v) (Ghc.mkVarOcc s)

mkCopyWithSuffix :: String -> Var -> Var
mkCopyWithSuffix s v = mkCopyWithName (Ghc.getOccString v ++ s) v

lookupBind :: Var -> [CoreBind] -> CoreBind
lookupBind x bs = case lookup x (concatMap binds bs) of
  Nothing -> F.panic $ "Not found definition for " ++ show x
  Just e  -> e
 where
  binds b@(NonRec x _) = [ (x, b) ]
  binds b@(Rec bs    ) = [ (x, b) | x <- fst <$> bs ]

subUnarySig :: CGEnv -> Var -> SpecType -> CG ()
subUnarySig γ x tRel =
  forM_ args $ \(rt, ut) -> addC (SubC γ ut rt) $ "subUnarySig tUn = " ++ F.showpp ut ++ " tRel = " ++ F.showpp rt
  where
    args = zip (snd $ vargs tRel) (snd $ vargs tUn)
    tUn = symbolType γ x $ "subUnarySig " ++ F.showpp x

addPred :: CGEnv -> F.Expr -> CG CGEnv
addPred γ p = extendWithExprs γ [p]

addPreds :: CGEnv -> [F.Expr] -> CG CGEnv
addPreds = extendWithExprs

extendWithExprs :: CGEnv -> [F.Expr] -> CG CGEnv 
extendWithExprs γ ps = do
  dummy <- fresh
  let reft = uReft (F.vv_, F.PAnd ps)
  γ += ("extend with predicate env", dummy, RVar (symbolRTyVar F.dummySymbol) reft)

unapplyArg :: F.Symbol -> F.Symbol -> F.Expr -> F.Expr
unapplyArg f y e = F.mapExpr sub e
  where 
    sub :: F.Expr -> F.Expr
    sub (F.EApp (F.EVar r) (F.EVar x)) 
      | r == f && x == y = F.EVar r
    sub e = e

unapplyRelArgs :: F.Symbol -> F.Symbol -> F.Expr -> F.Expr
unapplyRelArgs x1 x2 = unapplyArg resL x1 . unapplyArg resR x2

-- unRAllP :: SpecType -> SpecType
-- unRAllP (RAllP _ t       ) = unRAllP t
-- unRAllP (RAllT α t r     ) = RAllT α (unRAllP t) r
-- unRAllP (RImpF x t t' r  ) = RImpF x (unRAllP t) (unRAllP t') r
-- unRAllP (RFun  x t t' r  ) = RFun x (unRAllP t) (unRAllP t') r
-- unRAllP (RAllE  x t  t'  ) = RAllE x (unRAllP t) (unRAllP t')
-- unRAllP (REx    x t  t'  ) = REx x (unRAllP t) (unRAllP t')
-- unRAllP (RAppTy t t' r   ) = RAppTy (unRAllP t) (unRAllP t') r
-- unRAllP (RApp c   ts _ r) = RApp c (unRAllP <$> ts) [] r
-- unRAllP (RRTy xts r  o  t) = RRTy (mapSnd unRAllP <$> xts) r o (unRAllP t)
-- unRAllP (RVar t r        ) = RVar t mempty
-- unRAllP t                  = t

--------------------------------------------------------------
-- Debug -----------------------------------------------------
--------------------------------------------------------------

showType :: SpecType -> String
showType (RAllP _ t  ) = "RAllP " ++ showType t
showType (RAllT _ t _) = "RAllT " ++ showType t
showType (RImpF _ t t' _) =
  "RImpF(" ++ showType t ++ ", " ++ showType t' ++ ") "
showType (RFun _ t t' _) = "RFun(" ++ showType t ++ ", " ++ showType t' ++ ") "
showType (RAllE _ t t' ) = "RAllE(" ++ showType t ++ ", " ++ showType t' ++ ") "
showType (REx   _ t t' ) = "REx(" ++ showType t ++ ", " ++ showType t' ++ ") "
showType (RAppTy t t' _) =
  "RAppTy(" ++ showType t ++ ", " ++ showType t' ++ ") "
showType (RApp _ ts _ _) = "RApp" ++ show (showType <$> ts)
showType (RRTy xts _ _ t) =
  "RRTy("
    ++ show (map (\(_, t) -> showType t) xts)
    ++ ", "
    ++ showType t
    ++ ") "
showType v@(RVar _ _  ) = "RVar " ++ F.showpp v
showType v@(RExprArg _) = "RExprArg " ++ F.showpp v
showType v@(RHole    _) = "RHole" ++ F.showpp v

traceUnapply
  :: (PPrint x1, PPrint x2, PPrint e1, PPrint e2)
  => x1 -> x2 -> e1 -> e2 -> e2
traceUnapply x1 x2 e1 e2 = traceWhenLoud ("Unapply\n"
                      ++ "x1: " ++ F.showpp x1 ++ "\n\n"
                      ++ "x2: " ++ F.showpp x2 ++ "\n\n"
                      ++ "e1: " ++ F.showpp e1 ++ "\n\n"
                      ++ "e2: " ++ F.showpp e2) e2


traceSub 
  :: (PPrint t, PPrint s, PPrint p, PPrint q)
  => String -> t -> s -> p -> q -> a -> a
traceSub msg t s p q = traceWhenLoud (msg ++ " RelSub\n"
                      ++ "t: " ++ F.showpp t ++ "\n\n"
                      ++ "s: " ++ F.showpp s ++ "\n\n"
                      ++ "p: " ++ F.showpp p ++ "\n\n"
                      ++ "q: " ++ F.showpp q)


traceChk
  :: (PPrint e, PPrint d, PPrint t, PPrint s, PPrint p)
  => String -> e -> d -> t -> s -> p -> a -> a
traceChk expr = trace (expr ++ " To CHECK")

traceSyn
  :: (PPrint e, PPrint d, PPrint a, PPrint b, PPrint c) 
  => String -> e -> d -> CG (a, b, c) -> CG (a, b, c)
traceSyn expr e d cg 
  = do 
    (a, b, c) <- cg
    trace (expr ++ " To SYNTH") e d a b c cg

traceUSyn
  :: (PPrint e, PPrint a) 
  => String -> e -> CG a -> CG a
traceUSyn expr e cg = do
  t <- cg
  trace (expr ++ " To SYNTH UNARY") e dummy t dummy dummy cg
  where dummy = F.PTrue

trace
  :: (PPrint e, PPrint d, PPrint t, PPrint s, PPrint p)
  => String -> e -> d -> t -> s -> p -> a -> a
trace msg e d t s p = traceWhenLoud (msg ++ "\n"
                      ++ "e: " ++ F.showpp e ++ "\n\n"
                      ++ "d: " ++ F.showpp d ++ "\n\n"
                      ++ "t: " ++ F.showpp t ++ "\n\n"
                      ++ "s: " ++ F.showpp s ++ "\n\n"
                      ++ "p: " ++ F.showpp p)

traceWhenLoud :: String -> a -> a
traceWhenLoud s a = unsafePerformIO $ whenLoud (putStrLn s) >> return a