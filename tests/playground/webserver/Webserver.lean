import Lean
namespace Webserver

structure State :=
(verb : String)
(path : String)
(status := "200 OK")
(outHeaders : Array String := #[])
(tryNextHandler := false)

abbrev HandlerM := StateT State IO
abbrev Handler := HandlerM String

def checkVerb (verb : String) : HandlerM Unit := do
st ← get;
when (st.verb != verb) $
  throw $ IO.userError "invalid verb"

def checkPathLiteral (p : String) : HandlerM Unit := do
st ← get;
if p.isPrefixOf st.path then
  set { st with path := st.path.extract p.bsize st.path.bsize }
else
  throw $ IO.userError "invalid path"

def getPathPart : HandlerM String := do
st ← get;
let stop := st.path.posOf '/';
set { st with path := st.path.extract stop st.path.bsize };
pure $ st.path.extract 0 stop

def checkPathConsumed : HandlerM Unit := do
st ← get;
when (st.path != "") $
  throw $ IO.userError "invalid path"

def redirect (url : String) : Handler := do
modify $ fun st => { st with status := "301 Moved Permanently", outHeaders := #["Location: " ++ url] };
pure ""

def mkHandlersRef : IO (IO.Ref (List Handler)) :=
IO.mkRef ∅

@[init mkHandlersRef]
constant handlersRef : IO.Ref (List Handler) := arbitrary _

def registerHandler (h : Handler) : IO Unit := do
handlersRef.modify fun hs => h::hs

partial def parseHeaders : IO.FS.Handle → IO Unit
| hIn => do
  line ← hIn.getLine;
  if line == "" || line == "\r\n" then pure () else parseHeaders hIn

partial def run : IO.FS.Handle → IO.FS.Handle → IO Unit
| hIn, hOut => do
  line ← hIn.getLine;
  when (line != "") do
    [verb, path, proto] ← pure $ line.splitOn " "
      | panic! "failed to parse request: " ++ line;
    headers ← parseHeaders hIn;
    handler::handlers ← handlersRef.get | panic! "no handlers";
    (out, st) ← handlers.foldl (fun h₁ h₂ => h₁ <|> h₂) handler { verb := verb, path := path };
    hOut.putStrLn $ "HTTP/1.1 " ++ st.status;
    hOut.putStrLn "Content-Type: text/html";
    hOut.putStrLn $ "Content-Length: " ++ toString out.bsize;
    st.outHeaders.forM hOut.putStrLn;
    hOut.putStrLn "";
    hOut.putStr out;
    hOut.flush;
    run hIn hOut

end Webserver

new_frontend
open Lean

namespace Prelim
open Lean.Parser

-- for declaring simple parsers I can still use within other `syntax`
@[commandParser] def syntaxAbbrev := parser! symbol "syntax " >> ident >> symbol " := " >> many1 syntaxParser
@[macro Prelim.syntaxAbbrev] def elabSyntaxAbbrev : Macro :=
fun stx => match_syntax stx with
| `(syntax $id := $p*) => `(declare_syntax_cat $id  syntax:0 $p* : $id)
| _ => Macro.throwUnsupported

-- "JSXTextCharacter : SourceCharacter but not one of {, <, > or }"
def text : Parser := {
  fn := fun c s =>
    let startPos := s.pos;
    let s := takeWhile1Fn (fun c => not ("{<>}$".contains c)) "HTML text" c s;
    mkNodeToken `LX.text startPos c s }

def pathLiteral : Parser := {
  fn := fun c s =>
    let startPos := s.pos;
    let s := takeWhile1Fn (fun c => c == '/' || c.isAlphanum) "URL path" c s;
    mkNodeToken `pathLiteral startPos c s }

end Prelim

-- HACK: get `text` into `syntax` world
declare_syntax_cat text
@[textParser] def text := Prelim.text

declare_syntax_cat pathLiteral
@[pathLiteralParser] def pathLiteral := Prelim.pathLiteral

namespace LX

declare_syntax_cat element
declare_syntax_cat child

syntax "<" ident "/>" : element
syntax "<" ident ">" child* "</" ident ">" : element

syntax text : child
syntax element : child
syntax "{" term "}" : child

syntax element : term

macro_rules
| `(<$n/>) => mkStxStrLit ("<" ++ toString n.getId ++ ">")
| `(<$n>$cs*</$m>) =>
  if n.getId == m.getId then do
    cs ← cs.mapM fun c => match_syntax c with
      | `(child|$t:text)    => pure $ mkStxStrLit (t.getArg 0).getAtomVal!
      | `(child|{$t})       => pure t
      | `(child|$e:element) => `($e:element)
      | _                   => unreachable!;
    let cs := cs.push (mkStxStrLit ("</" ++ toString m.getId ++ ">"));
    cs.foldlM (fun s e => `($s ++ $e)) (mkStxStrLit ("<" ++ toString n.getId ++ ">"))
  else Macro.throwError m ("expected </" ++ toString n.getId ++ ">")

end LX

#eval
  let name := "PLDI";
  <html>
    <h1>Hello, {name}!</h1>
    <button/>
  </html>

--#eval <h1>oh no</h2>

open Webserver

declare_syntax_cat pathItem
declare_syntax_cat verb

syntax pathLiteral : pathItem
syntax "{" ident "}" : pathItem
syntax path := pathItem*

syntax "GET" : verb
syntax "POST" : verb

macro v:verb p:path " => " t:term : command => do
  t ← `(do checkPathConsumed; $t:term);
  t ← (p.getArg 0).getArgs.foldrM (fun pi t => match_syntax pi with
    | `(pathItem|$l:pathLiteral) => `(do checkPathLiteral $(mkStxStrLit (l.getArg 0).getAtomVal!); $t:term)
    | `(pathItem|{$id}) => `(do $id:ident ← getPathPart; $t:term)
    | _ => unreachable!) t;
  `(
def handler : Handler := do
checkVerb $(mkStxStrLit (v.getArg 0).getAtomVal!);
$t:term

@[init] def reg : IO Unit := registerHandler handler
  )

GET / =>
  redirect "/greet/stranger"
GET /greet/{name} => pure
  <html>
    <h1>Hello, {name}!</h1>
  </html>

def main : IO Unit := do
  hIn ← IO.stdin;
  hOut ← IO.stdout;
  Webserver.run hIn hOut
