module Clarify.Sigma
  ( cartesianSigma
  , returnArrayType
  , returnClosureType
  ) where

import Control.Monad.Except
import Control.Monad.State

import Clarify.Linearize
import Clarify.Utility
import Data.Basic
import Data.Code
import Data.Env

cartesianSigma ::
     Identifier
  -> Meta
  -> [Either CodePlus (Identifier, CodePlus)]
  -> WithEnv DataPlus
cartesianSigma thetaName m mxts = do
  aff <- affineSigma ("affine-" ++ thetaName) m mxts
  rel <- relevantSigma ("relevant-" ++ thetaName) m mxts
  return (m, DataSigmaIntro [aff, rel])

-- (Assuming `ti` = `return di` for some `di` such that `xi : di`)
-- affineSigma NAME LOC [(x1, t1), ..., (xn, tn)]   ~>
--   update CodeEnv with NAME ~> (thunk LAM), where LAM is:
--   lam z.
--     let (x1, ..., xn) := z in
--     <LINEARIZE_HEADER for x1, .., xn> in                     ---
--     bind y1 :=                                    ---        ---
--       bind f1 = t1 in              ---            ---        ---
--       let (aff-1, rel-1) = f1 in   ---  APP-1     ---        ---
--       aff-1 @ x1 in                ---            ---        ---
--     ...                                           ---  body  ---  body'
--     bind yn :=                                    ---        ---
--       bind fn = tn in              ---            ---        ---
--       let (aff-n, rel-n) := fn in  ---  APP-n     ---        ---
--       aff-n @ xn in                ---            ---        ---
--     return ()                                     ---        ---
--
-- (Note that sigma-elim for yi is not necessary since all of them are units.)
affineSigma ::
     Identifier
  -> Meta
  -> [Either CodePlus (Identifier, CodePlus)]
  -> WithEnv DataPlus
affineSigma thetaName m mxts = do
  cenv <- gets codeEnv
  let theta = (m, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      xts <- mapM supplyName mxts
      (z, varZ) <- newDataUpsilonWith "arg"
      -- As == [APP-1, ..., APP-n]   (`a` here stands for `app`)
      as <- forM xts $ \(x, t) -> toAffineApp m x t
      ys <- mapM (const $ newNameWith "arg") xts
      let body = bindLet (zip ys as) (m, CodeUpIntro (m, DataSigmaIntro []))
      body' <- linearize xts body
      insCodeEnv thetaName [z] (m, CodeSigmaElim xts varZ body')
      return theta

-- (Assuming `ti` = `return di` for some `di` such that `xi : di`)
-- relevantSigma NAME LOC [(x1, t1), ..., (xn, tn)]   ~>
--   update CodeEnv with NAME ~> (thunk LAM), where LAM is:
--   lam z.
--     let (x1, ..., xn) := z in
--     <LINEARIZE_HEADER for x1, .., xn> in                                      ---
--     bind pair-1 :=                                                  ---       ---
--       bind f1 = t1 in              ---                              ---       ---
--       let (aff-1, rel-1) = f1 in   ---  APP-1                       ---       ---
--       rel-1 @ x1 in                ---                              ---       ---
--     ...                                                             ---       ---
--     bind pair-n :=                                                  --- body  --- body'
--       bind fn = tn in              ---                              ---       ---
--       let (aff-n, rel-n) := fn in  ---  APP-n                       ---       ---
--       rel-n @ xn in                ---                              ---       ---
--     let (p11, p12) := pair-1 in               ---                   ---       ---
--     ...                                       ---  TRANSPOSED-PAIR  ---       ---
--     let (pn1, pn2) := pair-n in               ---                   ---       ---
--     return ((p11, ..., pn1), (p12, ..., pn2)) ---                   ---       ---
relevantSigma ::
     Identifier
  -> Meta
  -> [Either CodePlus (Identifier, CodePlus)]
  -> WithEnv DataPlus
relevantSigma thetaName m mxts = do
  cenv <- gets codeEnv
  let theta = (m, DataTheta thetaName)
  case lookup thetaName cenv of
    Just _ -> return theta
    Nothing -> do
      xts <- mapM supplyName mxts
      (z, varZ) <- newDataUpsilonWith "arg"
      -- as == [APP-1, ..., APP-n]
      as <- forM xts $ \(x, t) -> toRelevantApp m x t
      -- pairVarNameList == [pair-1, ...,  pair-n]
      (pairVarNameList, pairVarTypeList) <- unzip <$> mapM toPairInfo xts
      transposedPair <- transposeSigma pairVarTypeList
      let body = bindLet (zip pairVarNameList as) transposedPair
      body' <- linearize xts body
      insCodeEnv thetaName [z] (m, CodeSigmaElim xts varZ body')
      return theta

toPairInfo ::
     (Identifier, CodePlus) -> WithEnv (Identifier, (DataPlus, CodePlus))
toPairInfo (_, t) = do
  (name, var) <- newDataUpsilonWith "pair"
  return (name, (var, t))

-- transposeSigma [d1, ..., dn] :=
--   let (x1, y1) := d1 in
--   ...
--   let (xn, yn) := dn in
--   return ((x1, ..., xn), (y1, ..., yn))
transposeSigma :: [(DataPlus, CodePlus)] -> WithEnv CodePlus
transposeSigma ds = do
  (xVarNameList, xVarList) <-
    unzip <$> mapM (const $ newDataUpsilonWith "sig-x") ds
  (yVarNameList, yVarList) <-
    unzip <$> mapM (const $ newDataUpsilonWith "sig-y") ds
  return $
    bindSigmaElim (zip (zip xVarNameList yVarNameList) ds) $
    ( emptyMeta
    , CodeUpIntro
        ( emptyMeta
        , DataSigmaIntro
            [ (emptyMeta, DataSigmaIntro xVarList)
            , (emptyMeta, DataSigmaIntro yVarList)
            ]))

bindSigmaElim ::
     [((Identifier, Identifier), (DataPlus, CodePlus))] -> CodePlus -> CodePlus
bindSigmaElim [] cont = cont
bindSigmaElim (((x, y), (d, t)):xyds) cont = do
  let cont' = bindSigmaElim xyds cont
  (fst cont', CodeSigmaElim [(x, t), (y, t)] d cont')

supplyName :: Either b (Identifier, b) -> WithEnv (Identifier, b)
supplyName (Right (x, t)) = return (x, t)
supplyName (Left t) = do
  x <- newNameWith "unused-sigarg"
  return (x, t)

returnArrayType :: Meta -> WithEnv CodePlus
returnArrayType ml = do
  tau <- cartesianImmediate ml
  (arrVarName, arrVar) <- newDataUpsilonWith "arr"
  let retTau = (ml, CodeUpIntro tau)
  let retArrVar = (ml, CodeUpIntro arrVar)
  v <-
    cartesianSigma
      "array-closure"
      ml
      [Right (arrVarName, retTau), Left retArrVar]
  return (ml, CodeUpIntro v)

returnClosureType :: Meta -> WithEnv CodePlus
returnClosureType m = do
  imm <- cartesianImmediate m
  tau <- cartesianUniv m
  (envVarName, envVar) <- newDataUpsilonWith "env"
  let retUnivType = (m, CodeUpIntro tau)
  let retImmType = (m, CodeUpIntro imm)
  let retEnvVar = (m, CodeUpIntro envVar)
  closureType <-
    cartesianSigma
      "closure"
      m
      [Right (envVarName, retUnivType), Left retEnvVar, Left retImmType]
  return (m, CodeUpIntro closureType)