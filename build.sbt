name := "ota-lith"
organization := "io.github.uptane"
scalaVersion := "2.13.16"

updateOptions := updateOptions.value.withLatestSnapshots(false)

libraryDependencies ++= {
  val bouncyCastleV = "1.80"
  val pekkoV = "1.1.5"
  val pekkoHttpV = "1.2.0"

  Seq(
    "org.bouncycastle" % "bcprov-jdk18on" % bouncyCastleV,
    "org.bouncycastle" % "bcpkix-jdk18on" % bouncyCastleV,

    "org.apache.pekko" %% "pekko-actor" % pekkoV,
    "org.apache.pekko" %% "pekko-stream" % pekkoV,
    "org.apache.pekko" %% "pekko-http" % pekkoHttpV,
  )
}

lazy val treehub = (ProjectRef(file("./repos/treehub"), "treehub"))
lazy val director = (ProjectRef(file("./repos/director"), "director"))
lazy val keyserver = (ProjectRef(file("./repos/ota-tuf"), "keyserver"))
lazy val reposerver = (ProjectRef(file("./repos/ota-tuf"), "reposerver"))

dependsOn(treehub, director, keyserver, reposerver)

enablePlugins(BuildInfoPlugin, GitVersioning, JavaAppPackaging)

buildInfoOptions += BuildInfoOption.ToMap
buildInfoOptions += BuildInfoOption.BuildTime

Compile / mainClass := Some("com.advancedtelematic.ota_lith.OtaLithCombinedBoot")

import com.typesafe.sbt.packager.docker._
import sbt.Keys._
import com.typesafe.sbt.SbtNativePackager.Docker
import DockerPlugin.autoImport._
import com.github.sbt.git.SbtGit.git
import com.typesafe.sbt.SbtNativePackager.autoImport._
import com.typesafe.sbt.packager.linux.LinuxPlugin.autoImport._

Docker / dockerRepository := Some("uptane")

Docker / packageName := packageName.value

dockerUpdateLatest := true

Docker / dockerAliases ++= Seq(dockerAlias.value.withTag(git.gitHeadCommit.value))

Docker / defaultLinuxInstallLocation := s"/opt/${moduleName.value}"

dockerBaseImage := "eclipse-temurin:21-jre"

// Create writable runtime dirs (local TUF/treehub object storage + logs) owned by the
// image's non-root run-user. Injected right before native-packager's final USER switch so
// the mkdir/chown run as root. Works with the layered Docker build (unlike the old
// hand-written single-stage Dockerfile that hardcoded `ADD opt /opt`).
dockerCommands := {
  val name = moduleName.value
  // treehub/reposerver local blob stores require their parent dir to already exist and be
  // writable (see LocalFsBlobStore guard), so pre-create the object-storage roots used by
  // ota-lith-ce.conf. The named volume mounted at /var/lib/$name inherits these on first use.
  val mk = ExecCmd("RUN", "mkdir", "-p",
    s"/var/log/$name", s"/var/lib/$name/treehub-objects", s"/var/lib/$name/tuf-objects")
  val chown = ExecCmd("RUN", "chown", "-R", "1001:0", s"/var/log/$name", s"/var/lib/$name")
  dockerCommands.value.flatMap {
    case c @ Cmd("USER", args) if args.trim.nonEmpty && args.trim != "root" =>
      Seq(mk, chown, c)
    case c => Seq(c)
  }
}

// fork := true // TODO: Not compatible with .properties ?
