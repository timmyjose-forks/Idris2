module Compiler.Common

import Compiler.CompileExpr
import Compiler.Inline

import Core.Context
import Core.Directory
import Core.Options
import Core.TT
import Utils.Binary

import Data.NameMap

import System.Info

%include C "sys/stat.h"

||| Generic interface to some code generator
public export
record Codegen where
  constructor MkCG
  ||| Compile an Idris 2 expression, saving it to a file.
  compileExpr : Ref Ctxt Defs ->
                ClosedTerm -> (outfile : String) -> Core (Maybe String)
  ||| Execute an Idris 2 expression directly.
  executeExpr : Ref Ctxt Defs -> ClosedTerm -> Core ()

||| compile
||| Given a value of type Codegen, produce a standalone function
||| that executes the `compileExpr` method of the Codegen
export
compile : {auto c : Ref Ctxt Defs} ->
          Codegen ->
          ClosedTerm -> (outfile : String) -> Core (Maybe String)
compile {c} cg tm out
    = do makeExecDirectory
         cwd <- coreLift $ currentDir
         d <- getDirs
         coreLift $ changeDir (exec_dir d)
         fn <- compileExpr cg c tm out
         coreLift $ changeDir cwd
         pure fn

||| execute
||| As with `compile`, produce a functon that executes
||| the `executeExpr` method of the given Codegen
export
execute : {auto c : Ref Ctxt Defs} ->
          Codegen -> ClosedTerm -> Core ()
execute {c} cg tm
    = do makeExecDirectory
         cwd <- coreLift $ currentDir
         d <- getDirs
         coreLift $ changeDir (exec_dir d)
         executeExpr cg c tm
         coreLift $ changeDir cwd
         pure ()

-- ||| Recursively get all calls in a function definition
getAllDesc : List Name -> -- calls to check
             NameMap () ->  -- all descendants so far
             Defs -> Core (NameMap ())
getAllDesc [] ns defs = pure ns
getAllDesc (n :: rest) ns defs
  = case lookup n ns of
         Just _ => getAllDesc rest ns defs
         Nothing =>
            case !(lookupCtxtExact n (gamma defs)) of
                 Nothing => getAllDesc rest ns defs
                 Just def =>
                   let refs = refersTo def in
                       getAllDesc (rest ++ keys refs) (insert n () ns) defs


-- Calculate a unique tag for each type constructor name we're compiling
-- This is so that type constructor names get globally unique tags
mkNameTags : Defs -> NameTags -> Int -> List Name -> Core NameTags
mkNameTags defs tags t [] = pure tags
mkNameTags defs tags t (n :: ns)
    = case !(lookupDefExact n (gamma defs)) of
           Just (TCon _ _ _ _ _ _ _ _)
              => mkNameTags defs (insert n t tags) (t + 1) ns
           _ => mkNameTags defs tags t ns

natHackNames : List Name
natHackNames
    = [UN "prim__add_Integer",
       UN "prim__sub_Integer",
       UN "prim__mul_Integer",
       NS ["Prelude"] (UN "natToInteger"),
       NS ["Prelude"] (UN "integerToNat")]

-- Find all the names which need compiling, from a given expression, and compile
-- them to CExp form (and update that in the Defs)
export
findUsedNames : {auto c : Ref Ctxt Defs} -> Term vars ->
                Core (List Name, NameTags)
findUsedNames tm
    = do defs <- get Ctxt
         let ns = getRefs (Resolved (-1)) tm
         natHackNames' <- traverse toResolvedNames natHackNames
         allNs <- getAllDesc (natHackNames' ++ keys ns) empty defs
         cns <- traverse toFullNames (keys allNs)
         -- Initialise the type constructor list with explicit names for
         -- the primitives (this is how we look up the tags)
         -- Use '1' for '->' constructor
         let tyconInit = insert (UN "->") 1 $
                         insert (UN "Type") 2 $
                            primTags 3 empty
                                     [IntType, IntegerType, StringType,
                                      CharType, DoubleType, WorldType]
         tycontags <- mkNameTags defs tyconInit 100 cns
         traverse_ (compileDef tycontags) cns
         traverse_ inlineDef cns
         pure (cns, tycontags)
  where
    primTags : Int -> NameTags -> List Constant -> NameTags
    primTags t tags [] = tags
    primTags t tags (c :: cs)
        = primTags (t + 1) (insert (UN (show c)) t tags) cs

-- Some things missing from Prelude.File

||| check to see if a given file exists
export
exists : String -> IO Bool
exists f
    = do Right ok <- openFile f Read
             | Left err => pure False
         closeFile ok
         pure True

||| generate a temporary file/name
export
tmpName : IO String
tmpName = foreign FFI_C "tmpnam" (Ptr -> IO String) null

||| change the access rights for a file
export
chmod : String -> Int -> IO ()
chmod f m = foreign FFI_C "chmod" (String -> Int -> IO ()) f m

-- Parse a calling convention into a backend/target for the call, and
-- a comma separated list of any other location data.
-- e.g. "scheme:display" - call the scheme function 'display'
--      "C:puts,libc,stdio.h" - call the C function 'puts' which is in
--      the library libc and the header stdio.h
-- Returns Nothing if the string is empty (which a backend can interpret
-- however it likes)
export
parseCC : String -> Maybe (String, List String)
parseCC "" = Nothing
parseCC str
    = case span (/= ':') str of
           (target, "") => Just (trim target, [])
           (target, opts) => Just (trim target,
                                   map trim (getOpts
                                       (assert_total (strTail opts))))
  where
    getOpts : String -> List String
    getOpts "" = []
    getOpts str
        = case span (/= ',') str of
               (opt, "") => [opt]
               (opt, rest) => opt :: getOpts (assert_total (strTail rest))

export
dylib_suffix : String
dylib_suffix
    = cond [(os `elem` ["windows", "mingw32", "cygwin32"], "dll"),
            (os == "darwin", "dylib")]
           "so"

export
locate : {auto c : Ref Ctxt Defs} ->
         String -> Core (String, String)
locate libspec
    = do -- Attempt to turn libspec into an appropriate filename for the system
         let fname
              = case words libspec of
                     [] => ""
                     [fn] => if '.' `elem` unpack fn
                                then fn -- full filename given
                                else -- add system extension
                                     fn ++ "." ++ dylib_suffix
                     (fn :: ver :: _) =>
                          -- library and version given, build path name as
                          -- appropriate for the system
                          cond [(dylib_suffix == "dll",
                                      fn ++ "-" ++ ver ++ ".dll"),
                                (dylib_suffix == "dylib",
                                      fn ++ "." ++ ver ++ ".dylib")]
                                (fn ++ "." ++ dylib_suffix ++ "." ++ ver)

         fullname <- catch (findLibraryFile fname)
                           (\err => -- assume a system library so not
                                    -- in our library path
                                    pure fname)
         pure (fname, fullname)

export
copyLib : (String, String) -> Core ()
copyLib (lib, fullname)
    = if lib == fullname
         then pure ()
         else do Right bin <- coreLift $ readFromFile fullname
                    | Left err => throw (FileErr fullname err)
                 Right _ <- coreLift $ writeToFile lib bin
                    | Left err => throw (FileErr lib err)
                 pure ()
