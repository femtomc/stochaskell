module Language.Edward where

import Control.Monad
import Data.Expression hiding (const)
import Data.Expression.Const
import Data.Expression.Const.IO
import Data.List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Program
import Data.Ratio
import qualified Data.Set as Set
import System.Directory
import System.IO.Temp
import System.Process
import Util

dtype :: Type -> String
dtype t | t == boolT = "tf.bool"
dtype IntT = "tf.int32"
dtype RealT = "tf.float32"
dtype (ArrayT _ _ t) = dtype t

edId :: Id -> String
edId (Dummy    level i) =  "index_"++ show level ++"_"++ show i
edId (Volatile level i) = "sample_"++ show level ++"_"++ show i
edId (Internal level i) =  "value_"++ show level ++"_"++ show i

edNodeRef :: NodeRef -> String
edNodeRef (Var s _) = edId s
edNodeRef (Const c RealT) = show $ real c
edNodeRef (Const c _) = show c

edBuiltinFunctions =
  [("#>", "ed.dot")
  ]

edOperators =
  [("+",   "+")
  ]

edBuiltinDistributions =
  [("bernoulliLogits", ["Bernoulli", "logits"])
  ,("normal",          ["Normal",    "loc", "scale"])
  ,("normals",         ["Normal",    "loc", "scale"])
  ,("uniforms",        ["Uniform"])
  ]

edPrelude :: String
edPrelude = unlines
  ["import sys"
  ,"from collections import OrderedDict"
  ,"import edward as ed"
  ,"import numpy as np"
  ,"import tensorflow as tf"
  ]

edNode :: Map Id PNode -> Label -> Node -> String
edNode r _ (Apply "getExternal" [Var i t] _) =
  case Map.lookup i r of
    Just n  -> edPNode       (edId i) n
    Nothing -> edPlaceholder (edId i) t
edNode _ name (Apply op [i,j] _) | s /= "" =
  name ++" = "++ edNodeRef i ++" "++ s ++" "++ edNodeRef j
  where s = fromMaybe "" $ lookup op edOperators
edNode _ name (Apply f js _) =
  name ++" = "++ s ++"("++ edNodeRef `commas` js ++")"
  where s = fromMaybe f (lookup f edBuiltinFunctions)
edNode r name (Array sh dag ret (ArrayT _ _ t))
  | edDAG r dag /= "" = -- TODO: or ret depends on index
    "def "++ fn ++":\n"++
      edDAG r dag ++"\n  "++
      "return "++ edNodeRef ret ++"\n"++
    name ++" = tf.stack("++ go (inputs dag) sh ++")"
  | otherwise =
    name ++" = "++ edNodeRef ret ++" * tf.ones(["++
      edNodeRef `commas` map snd sh ++"], dtype="++ dtype t ++")"
  where fn = name ++"_fn("++ edId `commas` inputs dag ++")"
        go [] [] = fn
        go (i:is) ((a,b):sh) =
          "["++ go is sh ++" for "++ edId i ++" in xrange("++
            edNodeRef a ++", "++ edNodeRef b ++"+1)]"
edNode _ _ n = error $ "edNode "++ show n

edPNode :: Label -> PNode -> String
edPNode name (Dist f args t) | lookup f edBuiltinDistributions /= Nothing =
  name ++" = ed.models."++ c ++ "("++ ps ++")\n"++
  "dim_"++ name ++" = ["++ g `commas` typeDims t ++"]"
  where c:params = fromJust $ lookup f edBuiltinDistributions
        h p a = p ++"="++ edNodeRef a
        ps | null params = edNodeRef `commas` args
           | otherwise = intercalate ", " (zipWith h params args)
        g (a,b) = edNodeRef b ++"-"++ edNodeRef a ++"+1"

edPlaceholder :: Label -> Type -> String
edPlaceholder name t =
  name ++" = tf.Variable(np.load('"++ name ++".npy'), "++
                        "trainable=False, dtype="++ dtype t ++")"

edDAG :: Map Id PNode -> DAG -> String
edDAG r dag = indent . unlines . flip map (nodes dag) $ \(i,n) ->
  let name = edId $ Internal (dagLevel dag) i
  in edNode r name n

edProgram :: (ExprTuple t) => Int -> Int -> Double -> Prog t -> String
edProgram numSamples numSteps stepSize prog =
  edPrelude ++"\n"++
  "if True:\n"++
    edDAG pn (head block) ++"\n"++
  "latent = "++ printedRets ++"\n"++
  "data = "++ printedConds ++"\n"++
  "inference = ed.HMC(latent, data)\n"++
  "stdout = sys.stdout; sys.stdout = sys.stderr\n"++
  "inference.run(step_size="++ show stepSize ++
               ",n_steps="++ show numSteps ++")\n"++
  "sys.stdout = stdout\n"++
  "print(zip(*[q.params.eval().tolist() for q in latent.values()]))"
  where (rets, pb@(PBlock block _ given)) = runProgExprs prog
        skel = modelSkeleton pb
        pn = Map.filterWithKey (const . (`Set.member` skel)) $ pnodes pb
        printedRets = "OrderedDict(["++ g `commas` rets ++"])"
        g r = "("++ edNodeRef r ++", ed.models.Empirical(params=tf.Variable("++
                "tf.zeros(["++ show numSamples ++"] + dim_"++ edNodeRef r ++"))))"
        printedConds = "{"++ intercalate ", "
          [edId k ++": np.load('"++ edId k ++".npy')"
          | k <- Map.keys given, k `Set.member` skel] ++"}"

hmcEdward :: (ExprTuple t, Read t) => Int -> Int -> Double -> Prog t -> IO [t]
hmcEdward numSamples numSteps stepSize prog = withSystemTempDirectory "edward" $ \tmpDir -> do
  pwd <- getCurrentDirectory
  setCurrentDirectory tmpDir
  forM_ (Map.toList given) $ \(i,c) ->
    writeNPy (edId i ++".npy") c
  out <- readProcess (pwd ++"/edward/env/bin/python") [] $
    edProgram numSamples numSteps stepSize prog
  setCurrentDirectory pwd
  return (read out)
  where (_, PBlock _ _ given) = runProgExprs prog