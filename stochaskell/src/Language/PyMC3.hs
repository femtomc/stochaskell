{-# LANGUAGE RecordWildCards #-}

module Language.PyMC3 where

import Control.Monad
import Data.Expression hiding (const)
import Data.Expression.Const
import Data.Expression.Const.IO
import Data.Expression.Eval
import Data.List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Program
import qualified Data.Set as Set
import System.Directory
import System.IO.Temp
import System.Process
import Util

pmId :: Id -> String
pmId (Dummy    level i) =  "index_"++ show level ++"_"++ show i
pmId (Volatile level i) = "sample_"++ show level ++"_"++ show i
pmId (Internal level i) =  "value_"++ show level ++"_"++ show i

pmNodeRef :: NodeRef -> String
pmNodeRef (Var s _) = pmId s
pmNodeRef (Const c _) = show c

pmBuiltinFunctions =
  []

pmOperators =
  [("+",   "+")
  ]

pmBuiltinDistributions =
  [("bernoulli",       ["Bernoulli", "p"])
  ,("normal",          ["Normal",    "mu", "sd"])
  ,("normals",         ["Normal",    "mu", "sd"])
  ,("uniforms",        ["Uniform",   "lower", "upper"])
  ]

pmPrelude :: String
pmPrelude = unlines
  ["import numpy as np"
  ,"import pymc3 as pm"
  ,"import sys"
  ,"import theano.tensor as tt"
--  ,"from memory_profiler import profile"
  ]

pmNode :: (Map Id PNode, Env) -> Label -> Node -> String
pmNode (r,given) _ (Apply "getExternal" [Var i _] _) =
  case Map.lookup i r of
    Just n -> pmPNode (pmId i) n (Map.lookup i given)
    Nothing -> pmId i ++" = tt.as_tensor_variable(np.load('"++ pmId i ++".npy'))"
pmNode _ name (Apply "#>" [i,j] _) =
  name ++" = "++ pmNodeRef i ++".dot("++ pmNodeRef j ++")"
pmNode _ name (Apply op [i,j] _) | s /= "" =
  name ++" = "++ pmNodeRef i ++" "++ s ++" "++ pmNodeRef j
  where s = fromMaybe "" $ lookup op pmOperators
pmNode _ name (Apply f js _) =
  name ++" = "++ s ++"("++ pmNodeRef `commas` js ++")"
  where s = fromMaybe f (lookup f pmBuiltinFunctions)
pmNode r name (Array sh dag ret (ArrayT _ _ t))
  | pmDAG r dag /= "" = undefined -- TODO: or ret depends on index
  | otherwise = name ++" = "++ pmNodeRef ret ++" * np.ones(("++
                  pmNodeRef `commas` map snd sh ++"))"

pmPNode :: Label -> PNode -> Maybe ConstVal -> String
pmPNode name (Dist "bernoulliLogit" [l] t) =
  pmPNode' name "bernoulli" ["pm.invlogit("++ pmNodeRef l ++")"] t
pmPNode name (Dist "bernoulliLogits" args t) =
  pmPNode name (Dist "bernoulliLogit" args t)
pmPNode name (Dist f args t) = pmPNode' name f (map pmNodeRef args) t

pmPNode' :: Label -> String -> [String] -> Type -> Maybe ConstVal -> String
pmPNode' name f args t val | lookup f pmBuiltinDistributions /= Nothing =
  name ++" = pm."++ c ++ "('"++ name ++"', "++ ps ++", "++ obs ++
    "shape=("++ g `commas` typeDims t ++"))"
  where c:params = fromJust $ lookup f pmBuiltinDistributions
        h p a = p ++"="++ a
        ps = intercalate ", " (zipWith h params args)
        g (a,b) = pmNodeRef b ++"-"++ pmNodeRef a ++"+1"
        obs | val == Nothing = ""
            | otherwise = "observed=np.load('"++ name ++".npy'), "

pmDAG :: (Map Id PNode, Env) -> DAG -> String
pmDAG r dag = indent . unlines . flip map (nodes dag) $ \(i,n) ->
  let name = pmId $ Internal (dagLevel dag) i
  in pmNode r name n

pmProgram :: (ExprTuple t) => Prog t -> String
pmProgram prog =
  pmPrelude ++"\n"++
  --"@profile(stream=sys.stderr)\n"++
  "def main():\n"++
  " with pm.Model() as model:\n"++
    pmDAG (pn, given) (head block)
  where pb@(PBlock block _ given) = snd $ runProgExprs prog
        skel = modelSkeleton pb
        pn = Map.filterWithKey (const . (`Set.member` skel)) $ pnodes pb

data PyMC3Inference
  = PyMC3Sample
    { pmDraws :: Int
    , pmStep :: Maybe PyMC3Step
    , pmInit :: Maybe String
    , pmTune :: Int
    }

instance Show PyMC3Inference where
  show PyMC3Sample{..} = "pm.sample(draws="++ show pmDraws
                                ++",step="++ maybe "None" show pmStep
                                ++",init="++ maybe "None" show pmInit
                                ++",tune="++ show pmTune
                                ++")"

data PyMC3Step
  = NUTS
  | Metropolis
  | Slice
  | HamiltonianMC
    { pathLength :: Double
    , stepRand :: String
    , stepScale :: Double
    }

instance Show PyMC3Step where
  show NUTS = "pm.NUTS()"
  show Metropolis = "pm.Metropolis()"
  show Slice = "pm.Slice()"
  show HamiltonianMC{..} = "pm.HamiltonianMC(path_length="++ show pathLength
                                         ++",step_rand="++ stepRand
                                         ++",step_scale="++ show stepScale
                                         ++")"

defaultPyMC3Inference :: PyMC3Inference
defaultPyMC3Inference = PyMC3Sample
  { pmDraws = 500
  , pmStep = Nothing
  , pmInit = Just "auto"
  , pmTune = 500
  }

runPyMC3 :: (ExprTuple t, Read t) => PyMC3Inference -> Prog t -> IO [t]
runPyMC3 sample prog = withSystemTempDirectory "pymc3" $ \tmpDir -> do
  pwd <- getCurrentDirectory
  setCurrentDirectory tmpDir
  forM_ (Map.toList given) $ \(i,c) ->
    writeNPy (pmId i ++".npy") c
  writeFile "main.py" $
    pmProgram prog ++"\n  "++
    "trace = "++ show sample ++"; print(zip("++ g `commas` rets ++"))\n"++
    "main()"
  out <- readProcess (pwd ++"/pymc3/env/bin/python") ["main.py"] ""
  setCurrentDirectory pwd
  return (read out)
  where (rets, PBlock _ _ given) = runProgExprs prog
        g r = "trace['"++ pmNodeRef r ++"'].tolist()"