/-
Copyright (c) 2021 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/
import Lake.BuildTask
import Lake.BuildTrace

open System
namespace Lake

--------------------------------------------------------------------------------
-- # Target
--------------------------------------------------------------------------------

structure Target.{u,v} (t : Type u) (m : Type u → Type v) (a : Type u) where
  artifact  : a
  trace     : t
  task      : m PUnit

instance [Inhabited t] [Inhabited a] [Pure m] : Inhabited (Target t m a) :=
  ⟨Inhabited.default, Inhabited.default, pure ()⟩

namespace Target

def withTrace (trace : t) (self : Target r m a) : Target t m a :=
  {self with trace := trace}

def discardTrace (self : Target t m a) : Target PUnit m a :=
  self.withTrace ()

def withArtifact (artifact : a) (self : Target t m b) : Target t m a :=
  {self with artifact := artifact}

def discardArtifact (self : Target t m α) : Target t m PUnit :=
  self.withArtifact ()

def mtime (self : Target MTime m a) : MTime :=
  self.trace

def file (self : Target t m FilePath) : FilePath :=
  self.artifact

def filesList (self : Target t m (List FilePath)) : List FilePath :=
  self.artifact

def filesArray (self : Target t m (Array FilePath)) : Array FilePath :=
  self.artifact

end Target

--------------------------------------------------------------------------------
-- # Build Targets
--------------------------------------------------------------------------------

-- ## Active Build Target

abbrev ActiveBuildTarget t a :=
  Target t IOTask a

namespace ActiveBuildTarget

def mk (artifact : a) (trace : t) (task : BuildTask) : ActiveBuildTarget t a :=
  ⟨artifact, trace, task⟩

def opaque (trace : t) (task : BuildTask) : ActiveBuildTarget t PUnit :=
  ⟨(), trace, task⟩

protected def pure (artifact : a) (trace : t) : ActiveBuildTarget t a :=
  ⟨artifact, trace, BuildTask.nop⟩

def nil [Inhabited t] : ActiveBuildTarget t PUnit :=
  ActiveBuildTarget.pure () Inhabited.default

def materialize (self : ActiveBuildTarget t α) : IO PUnit :=
  self.task.await

-- ### Combinators

def after (target : ActiveBuildTarget t a) (act : IO PUnit)  : IO BuildTask :=
  afterTask target.task act

def afterList (targets : List (ActiveBuildTarget t a)) (act : IO PUnit) : IO BuildTask :=
  afterTaskList (targets.map (·.task)) act

instance : HAndThen (ActiveBuildTarget t a) (IO PUnit) (IO BuildTask) :=
  ⟨ActiveBuildTarget.after⟩

instance : HAndThen (List (ActiveBuildTarget t a)) (IO PUnit) (IO BuildTask) :=
  ⟨ActiveBuildTarget.afterList⟩

end ActiveBuildTarget

-- ## Build Target

abbrev BuildTarget t a :=
  Target t IO a

namespace BuildTarget

def mk (artifact : a) (trace : t) (task : IO PUnit) : BuildTarget t a :=
  ⟨artifact, trace, task⟩

def opaque (trace : t) (task : IO PUnit) : BuildTarget t PUnit :=
  ⟨(), trace, task⟩

protected def pure (artifact : a) (trace : t) : BuildTarget t a :=
  ⟨artifact, trace, pure ()⟩

def nil [Inhabited t] : BuildTarget t PUnit :=
  BuildTarget.pure () Inhabited.default

def spawn (self : BuildTarget t a) : IO (ActiveBuildTarget t a) := do
  return {self with task := (← IO.asTask self.task)}

def materialize (self : BuildTarget t a) : IO PUnit :=
  self.task

-- ### Combinators

def after (target : BuildTarget t a) (act : IO PUnit)  : IO PUnit :=
  target.task *> act

def afterList (targets : List (BuildTarget t a)) (act : IO PUnit) : IO PUnit :=
  targets.forM (·.task) *> act

instance : HAndThen (BuildTarget t a) (IO PUnit) (IO PUnit) :=
  ⟨BuildTarget.after⟩

instance : HAndThen (List (BuildTarget t a)) (IO PUnit) (IO PUnit) :=
  ⟨BuildTarget.afterList⟩

end BuildTarget

--------------------------------------------------------------------------------
-- # File Targets
--------------------------------------------------------------------------------

-- ## File Target

abbrev FileTarget :=
  BuildTarget MTime FilePath

namespace FileTarget

def mk (file : FilePath) (depMTime : MTime) (task : IO PUnit) : FileTarget :=
  ⟨file, depMTime, task⟩

def compute (file : FilePath) : IO FileTarget := do
  BuildTarget.pure file (← getMTime file)

protected def pure (file : FilePath) (depMTime : MTime) : FileTarget :=
  BuildTarget.pure file depMTime

end FileTarget

-- ## Files Target

abbrev FilesTarget :=
  BuildTarget MTime (Array FilePath)

namespace FilesTarget

def files (self : FilesTarget) : Array FilePath :=
  self.artifact

def filesAsList (self : FilesTarget) : List FilePath :=
  self.artifact.toList

def filesAsArray (self : FilesTarget) : Array FilePath :=
  self.artifact

def compute (files : Array FilePath) : IO FilesTarget := do
  BuildTarget.pure files (MTime.arrayMax <| ← files.mapM getMTime)

def singleton (target : FileTarget) : FilesTarget :=
  {target with artifact := #[target.file]}

def collectList (targets : List FileTarget) : FilesTarget :=
  let files := Array.mk <| targets.map (·.file)
  let mtime := MTime.listMax <| targets.map (·.mtime)
  BuildTarget.mk files mtime do
   (← targets.mapM (IOTask.spawn ·.task)).forM (·.await)

def collectArray (targets : Array FileTarget) : FilesTarget :=
  let files := targets.map (·.file)
  let mtime := MTime.arrayMax <| targets.map (·.mtime)
  BuildTarget.mk files mtime do
   (← targets.mapM (IOTask.spawn ·.task)).forM (·.await)

def collect (targets : Array FileTarget) : FilesTarget :=
  collectArray targets

end FilesTarget

instance : Coe FileTarget FilesTarget := ⟨FilesTarget.singleton⟩
instance : Coe (List FileTarget) FilesTarget := ⟨FilesTarget.collectList⟩
instance : Coe (Array FileTarget) FilesTarget := ⟨FilesTarget.collectArray⟩

-- ## Active File Target

abbrev ActiveFileTarget :=
  ActiveBuildTarget MTime FilePath

namespace ActiveFileTarget

def mk (file : FilePath) (depMTime : MTime) (task : BuildTask) : ActiveFileTarget :=
  ActiveBuildTarget.mk file depMTime task

protected def pure (file : FilePath) (depMTime : MTime) : ActiveFileTarget :=
  ActiveBuildTarget.pure file depMTime

end ActiveFileTarget

--------------------------------------------------------------------------------
-- # Lean Target
--------------------------------------------------------------------------------

abbrev LeanTarget a :=
  ActiveBuildTarget LeanTrace a

namespace LeanTarget

def nil : LeanTarget PUnit :=
  ActiveBuildTarget.pure () Inhabited.default

def hash (self : LeanTarget a) := self.trace.hash
def mtime (self : LeanTarget a) := self.trace.mtime

def all (targets : List (LeanTarget a)) : IO (LeanTarget PUnit) := do
  let hash := Hash.foldList 0 <| targets.map (·.hash)
  let mtime := MTime.listMax <| targets.map (·.mtime)
  let task ← BuildTask.all <| targets.map (·.task)
  return ActiveBuildTarget.mk () ⟨hash, mtime⟩ task

def fromMTimeTarget (target : ActiveBuildTarget MTime a) : LeanTarget a :=
  {target with trace := LeanTrace.fromMTime target.trace}

def buildOpaqueFromFileTarget (target : FileTarget) : IO (LeanTarget PUnit) := do
  LeanTarget.fromMTimeTarget <| ← BuildTarget.spawn target.discardArtifact

end LeanTarget
