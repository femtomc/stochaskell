module Language.Stan where

import Control.Applicative ()
import Data.Array.Abstract
import qualified Data.ByteString.Char8 as C
import Data.Expression hiding (const)
import Data.Expression.Const
import Data.Expression.Eval
import Data.List
import Data.List.Split
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Program
import Data.Ratio
import Debug.Trace
import qualified Crypto.Hash.SHA1 as SHA1
import GHC.Exts
import System.Directory
import System.IO.Temp
import System.Process
import Util

-- TODO: better handling for exceptions to 1-based indexing

------------------------------------------------------------------------------
-- UTILITY FUNCTIONS                                                        --
------------------------------------------------------------------------------

commas :: (a -> String) -> [a] -> String
commas f xs = intercalate ", " $ map f xs

forLoop :: [Id] -> [Interval NodeRef] -> String -> String
forLoop is sh body = concat (zipWith f is sh) ++"{\n"++ body ++"\n}"
    where f i (a,b) =
            "for ("++ stanId i ++" in "++ stanNodeRef a
                                  ++":"++ stanNodeRef b ++") "


------------------------------------------------------------------------------
-- IDENTIFIERS                                                              --
------------------------------------------------------------------------------

stanId :: Id -> String
stanId (Dummy    level i) =  "index_"++ show level ++"_"++ show i
stanId (Volatile level i) = "sample_"++ show level ++"_"++ show i
stanId (Internal level i) =  "value_"++ show level ++"_"++ show i

stanConstVal :: ConstVal -> String
stanConstVal (Exact a) | isScalar a =
    if d == 1 then show n else show (fromRational c :: Double)
  where c = toScalar a
        n = numerator c
        d = denominator c
stanConstVal (Approx a) | isScalar a = show (toScalar a)
stanConstVal val | dimension val == 1 =
  "c("++ stanConstVal `commas` toList val ++")"
stanConstVal val =
  "structure("++ stanConstVal (vectorise val) ++", .Dim = "++ stanConstVal dim ++")"
  where (lo,hi) = bounds val
        dim = fromList $ integer <$> hi

stanNodeRef :: NodeRef -> String
stanNodeRef (Var s _) = stanId s
stanNodeRef (Const c) = stanConstVal c
stanNodeRef (Index f js) =
    stanNodeRef f ++"["++ stanNodeRef `commas` reverse js ++"]"


------------------------------------------------------------------------------
-- TYPES                                                                    --
------------------------------------------------------------------------------

stanType :: Type -> String
stanType IntT = "int"
stanType RealT = "real"
stanType (SubrangeT t _ _) = stanType t
{- TODO only enable at top-level:
stanType (SubrangeT t Nothing  Nothing ) = stan t
stanType (SubrangeT t (Just l) Nothing ) = stan t ++"<lower="++ stan l ++">"
stanType (SubrangeT t Nothing  (Just h)) = stan t ++"<upper="++ stan h ++">"
stanType (SubrangeT t (Just l) (Just h)) = stan t ++"<lower="++ stan l ++
                                                    ",upper="++ stan h ++">"
-}
stanType (ArrayT kind n t) =
    fromMaybe (stanType t) kind ++
      "["++ stanNodeRef `commas` map snd n ++"]"

stanDecl :: Label -> Type -> String
stanDecl name (ArrayT Nothing n t) =
    stanType t ++" "++ name ++
      "["++ stanNodeRef `commas` map snd n ++"];"
stanDecl name t = stanType t ++" "++ name ++";"


------------------------------------------------------------------------------
-- NODES                                                                    --
------------------------------------------------------------------------------

stanBuiltinFunctions =
  [("asVector",    "to_vector")
  ,("asMatrix",    "to_matrix")
  ,("chol",        "cholesky_decompose")
  ,("negate",      "-")
  ,("inv",         "inverse")
  ]

stanBuiltinDistributions =
  [("bernoulliLogit",  "bernoulli_logit")
  ]

stanOperators =
  [("+",   "+")
  ,("-",   "-")
  ,("*",   "*")
  ,("/",   "/")
  ,("==",  "==")
  ,("#>",  "*")
  ,("<>",  "*")
  ,("*>",  "*")
  ,("**",  "^")
  ]

stanNode :: Label -> Node -> String
stanNode name (Apply "ifThenElse" [a,b,c] _) =
    name ++" = "++ stanNodeRef a ++" ? "++ stanNodeRef b ++" : "++ stanNodeRef c ++";"
stanNode name (Apply "tr'" [a] _) =
    name ++" = "++ stanNodeRef a ++"';"
stanNode name (Apply op [i,j] _) | s /= "" =
    name ++" = "++ stanNodeRef i ++" "++ s ++" "++ stanNodeRef j ++";"
  where s = fromMaybe "" $ lookup op stanOperators
stanNode name (Apply f js _) =
    name ++" = "++ fromMaybe f (lookup f stanBuiltinFunctions) ++
      "("++ stanNodeRef `commas` js ++");"
stanNode name (Array sh dag ret _) =
    forLoop (inputs dag) sh $
        stanDAG dag ++"\n  "++
        name ++"["++ stanId  `commas` inputs dag ++"] = "++ stanNodeRef ret ++";"
stanNode name (Fold Right_ dag ret seed (Var ls at@(ArrayT _ ((lo,hi):_) _)) t) =
    name ++" = "++ stanNodeRef seed ++";\n"++ loop
  where d = dagLevel dag
        idx = Dummy d 0
        [i,j] = inputs dag
        s = typeIndex at
        loop =
          forLoop [idx] [(lo,hi)] $ "  "++
           stanDecl (stanId i) s ++"\n  "++
           stanDecl (stanId j) t ++"\n  "++
           stanId i ++" = "++ stanId ls ++"["++
             stanNodeRef lo ++"+"++ stanNodeRef hi ++"-"++ stanId idx ++"];\n  "++
           stanId j ++" = "++ name ++";\n  {\n"++
           stanDAG dag ++"\n  "++
           name ++" = "++ stanNodeRef ret ++";\n  }"
stanNode _ node = error $ "unable to codegen node "++ show node

stanPNode :: Label -> PNode -> String
stanPNode name (Dist f args _) =
    name ++" ~ "++ fromMaybe f (lookup f stanBuiltinDistributions) ++
      "("++ stanNodeRef `commas` args ++");"
stanPNode name (Loop sh ldag body _) =
    forLoop (inputs ldag) sh $
        let lval = name ++"["++ stanId `commas` inputs ldag ++"]"
        in stanDAG ldag ++ indent (stanPNode lval body)
stanPNode name (HODist "orderedSample" d [n] _) =
    forLoop [Dummy 1 1] [(Const 1,n)] $
        let lval = name ++"["++ stanId (Dummy 1 1) ++"]"
        in indent (stanPNode lval d)

stanDAG :: DAG -> String
stanDAG dag = indent $
    extract (\name -> stanDecl name . typeNode) ++
    extract stanNode
  where extract f = unlines . flip map (nodes dag) $ \(i,n) ->
                        let name = stanId $ Internal (dagLevel dag) i
                        in f name n


------------------------------------------------------------------------------
-- WHOLE PROGRAMS                                                           --
------------------------------------------------------------------------------

stanProgram :: PBlock -> String
stanProgram (PBlock block refs given) =
    "data {\n"++ printRefs (\i n ->
        if getId i `elem` map (Just . fst) (Map.toList given)
        then stanDecl (stanNodeRef i) (typePNode n) else "") ++"\n}\n"++
    "parameters {\n"++ printRefs (\i n ->
        if getId i `elem` map (Just . fst) (Map.toList given)
        then "" else stanDecl (stanNodeRef i) (typePNode n)) ++"\n}\n"++
    "transformed parameters {\n"++ stanDAG (head block) ++"\n}\n"++
    "model {\n"++ printRefs (\i n -> stanPNode (stanNodeRef i) n) ++"\n}\n"
  where printRefs f = indent . unlines $ zipWith g [0..] (reverse refs)
          where g i n = f (Var (Volatile 0 i) (typePNode n)) n

system' :: String -> IO ()
system' cmd = do
    putStrLn cmd
    system cmd
    return ()

runStan :: (ExprTuple t) => (String -> IO String) -> Int -> Prog t -> IO [t]
runStan extraArgs numSamples prog = withSystemTempDirectory "stan" $ \tmpDir -> do
    let basename = tmpDir ++"/stan"
    pwd <- getCurrentDirectory
    let hash = toHex . SHA1.hash . C.pack $ stanProgram p
        exename = pwd ++"/cache/stan/model_"++ hash
    exeExists <- doesFileExist exename

    if exeExists then return () else do
      putStrLn "--- Generating Stan code ---"
      putStrLn $ stanProgram p
      writeFile (exename ++".stan") $ stanProgram p
      system' $ "make -C "++ pwd ++"/cmdstan "++ exename
      return ()

    putStrLn "--- Sampling Stan model ---"
    let dat = unlines . flip map (Map.toList $ constraints p) $ \(n,x) ->
                stanId n ++" <- "++ stanConstVal x
    putStrLn dat
    writeFile (basename ++".data") dat
    -- TODO: avoid shell injection
    args <- extraArgs basename
    system' $ exename ++" sample num_samples="++ show numSamples ++
                               " num_warmup="++  show numSamples ++
                        " data   file="++ basename ++".data "++
                        " output file="++ basename ++".csv "++ args
    content <- readFile $ basename ++".csv"
    putStrLn $ "Extracting: "++ stanNodeRef `commas` rets

    putStrLn "--- Removing temporary files ---"
    return $ extractCSV content
  where (rets,p) = runProgExprs prog
        extractCSV content = map f (tail table)
          where noComment row = row /= "" && head row /= '#'
                table = map (splitOn ",") . filter noComment $ lines content
                readDouble = read :: String -> Double
                slice xs = map (xs !!)
                f row = fromConstVals $ do
                  r <- rets
                  return $ case stanNodeRef r `elemIndex` head table of
                    Just col -> real . readDouble $ row !! col
                    Nothing ->
                      let prefix = stanNodeRef r ++ "."
                          cols = isPrefixOf prefix `findIndices` head table
                      in fromList (real . readDouble <$> row `slice` cols)

hmcStan :: (ExprTuple t) => Prog t -> IO [t]
hmcStan = runStan (const $ return "") 1000

hmcStanInit :: (ExprTuple t) => Prog t -> t -> IO [t]
hmcStanInit = hmcStanInit' 1000

hmcStanInit' :: (ExprTuple t) => Int -> Prog t -> t -> IO [t]
hmcStanInit' numSamples p t = runStan extraArgs numSamples p
  where assigns = unlines . map f . Map.toList $ unifyTuple' (definitions pb) rets t env
        f (n,x) = stanId n ++" <- "++ stanConstVal x
        (rets,pb) = runProgExprs p
        env = constraints pb
        extraArgs basename = do
          let fname = basename ++".init"
          putStrLn assigns
          fname `writeFile` assigns
          return $ "init="++ fname
