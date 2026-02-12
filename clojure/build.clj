(ns build
  (:require [clojure.tools.build.api :as b]
            [deps-deploy.deps-deploy :as dd]))

(def lib 'net.clojars.jeremiahisaacson/copilot-sdk-supercharged)
(def version (or (System/getenv "VERSION") "1.0.0"))
(def class-dir "target/classes")
(def basis (delay (b/create-basis {:project "deps.edn"})))
(def jar-file (format "target/%s-%s.jar" (name lib) version))

(defn clean [_]
  (b/delete {:path "target"}))

(defn jar [_]
  (clean nil)
  (b/write-pom {:class-dir class-dir
                :lib lib
                :version version
                :basis @basis
                :src-dirs ["src"]
                :scm {:url "https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged"
                      :connection "scm:git:https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged.git"
                      :tag (str "v" version)}
                :pom-data [[:description "GitHub Copilot SDK Supercharged for Clojure"]
                           [:url "https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged"]
                           [:licenses
                            [:license
                             [:name "MIT"]
                             [:url "https://opensource.org/licenses/MIT"]]]]})
  (b/copy-dir {:src-dirs ["src"]
               :target-dir class-dir})
  (b/jar {:class-dir class-dir
          :jar-file jar-file}))

(defn deploy [_]
  (jar nil)
  (dd/deploy {:installer :remote
              :artifact jar-file
              :pom-file (b/pom-path {:lib lib :class-dir class-dir})}))
