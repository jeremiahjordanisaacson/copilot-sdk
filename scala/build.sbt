val scala3Version = "3.4.2"

lazy val root = project
  .in(file("."))
  .settings(
    name := "copilot-sdk-supercharged",
    version := "0.1.0",
    scalaVersion := scala3Version,
    organization := "com.github.copilot",
    description := "Scala SDK for the GitHub Copilot CLI",

    libraryDependencies ++= Seq(
      "io.circe" %% "circe-core"    % "0.14.9",
      "io.circe" %% "circe-generic" % "0.14.9",
      "io.circe" %% "circe-parser"  % "0.14.9",
      "org.scalatest" %% "scalatest" % "3.2.19" % Test,
    ),

    scalacOptions ++= Seq(
      "-deprecation",
      "-feature",
      "-unchecked",
      "-Xfatal-warnings",
    ),
  )
