;;; -*- mode: emacs-lisp ; coding: utf-8-unix ; lexical-binding: nil -*-
;;; last updated : 2015/01/31.18:59:47

;; Copyright (C) 2013-2015  yaruopooner
;; 
;; Author          : yaruopooner [https://github.com/yaruopooner]
;; Keywords        : languages, completion, syntax check, mode, convenience

;; This file is part of MSVC.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:



(require 'cl-lib)
(require 'cedet-files)
(require 'msvc-env)



;; project file importer
(defconst msvc-flags:vcx-proj-name "msvc-extractor.cflags.vcxproj")
(defconst msvc-flags:vcx-proj-file (expand-file-name msvc-flags:vcx-proj-name msvc-env:package-directory))


(defconst msvc-flags:db-log-cflags "cflags.log")


(defconst msvc-flags:compile-file-name "empty.cpp")
(defconst msvc-flags:compile-file (expand-file-name msvc-flags:compile-file-name msvc-env:package-directory))


;; process & bind buffer name
(defconst msvc-flags:process-name "msvc-flags-generator")
(defconst msvc-flags:process-buffer-name-prefix "MSVC cflags")
(defconst msvc-flags:process-buffer-name-fmt (concat "*" msvc-flags:process-buffer-name-prefix "<%s>*"))
(defconst msvc-flags:process-buffer-name-pattern (concat "*" msvc-flags:process-buffer-name-prefix "<\\([^>]+\\)>*"))


;; search keywords
(defconst msvc-flags:collect-pattern "#CFLAG#:\\([^:]*\\):\\(.*\\)$")
(defconst msvc-flags:collect-keys '(
                                   "CFLAG_TargetMachine"
                                   "CFLAG_SystemPreprocessorDefinitions"
                                   "CFLAG_AdditionalPreprocessorDefinitions"
                                   "CFLAG_UndefinePreprocessorDefinitions"
                                   "CFLAG_SystemIncludePath"
                                   "CFLAG_AdditionalIncludePath"
                                   "CFLAG_ExcludePath"
                                   "CFLAG_ForceIncludeFiles"
                                   ;; "CFLAG_TargetSourceFiles"
                                   ;; "CFLAG_TargetHeaderFiles"
                                   "CFLAG_TargetFilesAbs"

                                   "ClCompile.DisableLanguageExtensions"
                                   "ClCompile.ExceptionHandling"
                                   "ClCompile.RuntimeTypeInfo"
                                   "ClCompile.CompileAs"
                                   "ClCompile.PrecompiledHeader"
                                   "ClCompile.PrecompiledHeaderFile"
                                   ))


;; database store path
(defvar msvc-flags:db-root-path (locate-user-emacs-file "msvc-db/"))


;; using path style
(defvar msvc-flags:clang-path-format nil
  "clang include path style
`nil'          : native style
`posix'        : posix style
")


;; CFLAGS/CXXFLAGS Database : Microsoft Visual C/C++ Project's CFLAGS/CXXFLAGS
(defvar msvc-flags:cflags-db nil "Generated CFLAGS/CXXFLAGS Database per vcx-project + Platform + Configuration + Version.")


;; delete the buffer after end of parse.
(defvar msvc-flags:parsing-buffer-delete-p nil)


;; sentinel flag
(defvar msvc-flags:parsing-p nil)
(defvar msvc-flags:parse-requests nil)




(defun msvc-flags:create-db-name (vcx-proj-path platform configuration version)
  (cedet-directory-name-to-file-name 
   (expand-file-name version (expand-file-name configuration (expand-file-name platform (file-name-sans-extension vcx-proj-path))))))

(defun msvc-flags:create-db-path (db-name)
  (file-name-as-directory (expand-file-name db-name msvc-flags:db-root-path)))


(defun msvc-flags:create-project-property (db-name)
  (let* ((parsing-path (cedet-file-name-to-directory-name db-name))
         (version (file-name-nondirectory parsing-path))
         (configuration (file-name-nondirectory (setq parsing-path (directory-file-name (file-name-directory parsing-path)))))
         (platform (file-name-nondirectory (setq parsing-path (directory-file-name (file-name-directory parsing-path)))))
         (project-file (concat (setq parsing-path (directory-file-name (file-name-directory parsing-path))) ".vcxproj")))

    `(:project-file ,project-file :platform ,platform :configuration ,configuration :version ,version)))


(defun msvc-flags:create-project-path (db-name)
  ;; project-path/project-file-name/platform/configuration/version -> project-path/project-file-name/
  (expand-file-name "../../../../" (cedet-file-name-to-directory-name db-name)))



(defun msvc-flags:regist-db (db-name cflags)
  ;; if already exist on database > remove element
  (setq msvc-flags:cflags-db (delete (assoc-string db-name msvc-flags:cflags-db) msvc-flags:cflags-db))
  (add-to-list 'msvc-flags:cflags-db `(,db-name . ,cflags) t))


(defun msvc-flags:query-cflags (db-name)
  "CFLAGS/CXXFLAGS Query. return Database : Microsoft Visual C/C++ Project's CFLAGS/CXXFLAGS"
  (cdr (assoc-string db-name msvc-flags:cflags-db)))

(defun msvc-flags:query-cflag (db-name cflag-name)
  "CFLAG/CXXFLAG Query. return flag values."
  (cdr (assoc-string cflag-name (msvc-flags:query-cflags db-name))))



(defun msvc-flags:get-db-name-from-buffer (buffer)
  (let* ((bind-name (buffer-name buffer)))
    (when (string-match msvc-flags:process-buffer-name-pattern bind-name)
      (match-string 1 bind-name))))



;; パース系の基底関数
;; 指定バッファをパースして CFLAGS を返す
;; 必要があればバッファを削除
;; これは set-process-sentinel に登録された msvc-flags:process-sentinel からも呼び出される
(defun msvc-flags:parse-compilation-buffer (buffer)
  (let* ((pattern msvc-flags:collect-pattern)
         (collect-keys msvc-flags:collect-keys)
         key
         value
         cflags)

    (with-current-buffer buffer
      (goto-char (point-min))
      (while (re-search-forward pattern nil t)
        (setq key (match-string 1))
        (setq value (match-string 2))
        (when (assoc-string key collect-keys)
          ;; パスのバックスラッシュ等は再置換
          (setq value (replace-regexp-in-string "[\\\\]+" "/" value))
          ;; セパレーター';' で分割して格納
          (setq value (split-string value ";" t))
          (when value
            (add-to-list 'cflags `(,key . ,value) t))))

      ;; パース後はリードオンリーとして残す
      (setq buffer-read-only t)
      ;; パース後にバッファ削除指定がある場合はそれを行う
      (when msvc-flags:parsing-buffer-delete-p
        (kill-buffer)))

    cflags))


;; for async parse
(defvar msvc-flags:after-parse-hooks nil
  "Abnormal hook that is run after a parsed file.")
;; :'(db-name)
;; :type 'hook)
;; :group 'files)
;; )

(defvar msvc-flags:after-all-parse-hook nil
  "Normal hook that is run after an all parsed file.")
;; :'(db-names)
;; :type 'hook
;; :group 'files)
;; )

(defun msvc-flags:process-sentinel (process _event)
  (when (memq (process-status process) '(signal exit))
    (let* ((exit-status (process-exit-status process))
           (bind-buffer (process-buffer process))
           (db-name (msvc-flags:get-db-name-from-buffer bind-buffer))
           (cflags (msvc-flags:parse-compilation-buffer bind-buffer)))

      (when db-name
        (msvc-flags:regist-db db-name cflags)
        (run-hook-with-args 'msvc-flags:after-parse-hooks db-name)))
    ;; parse finished

    ;; parsing flag off
    (setq msvc-flags:parsing-p nil)

    ;; next parse search & exec
    (let (request)
      (while (and (not msvc-flags:parsing-p) (setq request (pop msvc-flags:parse-requests)))
        (apply 'msvc-flags:parse-vcx-project request))
      ;; final request check
      (when (and (not msvc-flags:parsing-p) (null msvc-flags:parse-requests))
        ;; this sentinel is final request.
        ;; final sentinel hook exec
        ;; (apply final-hook args)
        (run-hooks 'msvc-flags:after-all-parse-hook)
        ))))





;; 指定db-name のログファイルをパースして CFLAGS を返す
(defun msvc-flags:parse-compilation-db (db-name)
  (let* ((db-path (msvc-flags:create-db-path db-name))
         (log-file (expand-file-name msvc-flags:db-log-cflags db-path))
         (parse-buffer (format msvc-flags:process-buffer-name-fmt db-name)))

    (when (file-readable-p log-file)
      ;; どの変数が local variable になっているか不明なので、いったん削除しておくのが安全
      (when (get-buffer parse-buffer)
        (kill-buffer parse-buffer))
      (when (get-buffer-create parse-buffer)
        (with-current-buffer parse-buffer
          ;; parse-bufferを該当ファイルで置き換える
          (insert-file-contents log-file nil nil nil t)
          (msvc-flags:parse-compilation-buffer parse-buffer))))))




;; バッファは同一名ではなく、Project+Platform+Configuration 毎に異なるバッファをバインドするので平行処理できる
;; バッファ名規則は、 (format msvc-flags:process-buffer-name-fmt db-name) とする
;; バッファ名はユニークになるように生成されて start-process-shell-command に渡される
;; これにより異なるプロジェクトのパースを同時実行できる
;; 出力バッファを自動削除するかは、フラグで判定
(defun msvc-flags:parse-execute ()
  ;; コマンド実行部分をこっちに移す
  )


(cl-defun msvc-flags:parse-vcx-project (&rest args)
  "parse *.vcxproj file : Microsoft Visual Studio
attributes
:project-file
:platform
:configuration
:version

optionals
:parsing-buffer-delete-p
:force-parse-p
:sync-p
"

  (interactive)

  ;; product not detected MSVC
  (unless msvc-env:product-detected-p
    (message "msvc-flags : product not detected : Microsoft Visual Studio")
    (cl-return-from msvc-flags:parse-vcx-project nil))

  ;; get property from args
  (let ((project-file (plist-get args :project-file))
        (platform (plist-get args :platform))
        (configuration (plist-get args :configuration))
        (version (plist-get args :version))
        (parsing-buffer-delete-p (plist-get args :parsing-buffer-delete-p))
        (force-parse-p (plist-get args :force-parse-p))
        (sync-p (plist-get args :sync-p)))

    ;; file extension check
    (unless (eq (compare-strings (file-name-extension project-file) nil nil "vcxproj" nil nil t) t)
      (message "msvc-flags : This file is not project file. : %s" project-file)
      (cl-return-from msvc-flags:parse-vcx-project nil))

    ;; project file exist check
    (unless (file-readable-p project-file)
      (message "msvc-flags : Project File Not Found. : %s" project-file)
      (cl-return-from msvc-flags:parse-vcx-project nil))

    ;; create database root directory
    (unless (file-accessible-directory-p msvc-flags:db-root-path)
      (make-directory msvc-flags:db-root-path))

    (let* ((db-name (msvc-flags:create-db-name project-file platform configuration version))
           (db-path (msvc-flags:create-db-path db-name))

           (log-file (expand-file-name msvc-flags:db-log-cflags db-path))
           (parse-p (or force-parse-p (file-newer-than-file-p project-file log-file))))

      ;; project file and db-log file compare date check
      (unless parse-p
        (message "msvc-flags : This project is already parsed.")
        (cl-return-from msvc-flags:parse-vcx-project db-name))

      ;; パース実行中の場合はリクエストリストへ登録
      (when msvc-flags:parsing-p
        (add-to-list 'msvc-flags:parse-requests args t)
        (cl-return-from msvc-flags:parse-vcx-project db-name))


      (message "msvc-flags : Parsing db-name : %s" db-name)


      ;; parsing flag on
      (setq msvc-flags:parsing-p t)

      (let* ((project-path (file-name-directory project-file))

             (msb-rsp-file (expand-file-name "cflags.rsp" db-path))
             (msb-target-file (expand-file-name msvc-flags:vcx-proj-name project-path))

             (process-name msvc-flags:process-name)
             (process-bind-buffer (format msvc-flags:process-buffer-name-fmt db-name))
             ;; bind connection type (use pipe)
             (process-connection-type nil)
             ;; bind encoding system (logfile:utf-8-dos, buffer:utf-8-unix)
             (default-process-coding-system '(utf-8-dos . utf-8-unix))

             (command (shell-quote-argument msvc-env:invoke-command))
             (command-args (msvc-env:build-msb-command-args version msb-rsp-file log-file)))

        ;; db-path ディレクトリはあらかじめ作成しておく必要がある
        ;; プロセス開始前に *.rsp を生成・保存する必要がある
        ;; リダイレクトorロガー指定が無い場合
        ;; MSBuildは自動的にdb-pathを作成するが、
        ;; リダイレクトがある場合はMSBuild 実行前にリダイレクトにより db-path へ log-file が出力されるため
        ;; 出力先ディレクトリが先に存在している必要がある
        ;; MSBuild logger も同上の理由だとおもわれる
        (unless (file-accessible-directory-p db-path)
          (make-directory db-path))

        ;; 強制パース時はrspに記述すべき構成に変化があったとみなして全て削除
        (when force-parse-p
          (msvc-env:remove-msb-rsp-files db-path))

        ;; プロジェクトファイルと同じ場所にインポートプロジェクトが配置されている必要がある
        ;; MSBuild の仕様のため(詳細後述)
        (when (file-newer-than-file-p msvc-flags:vcx-proj-file msb-target-file)
          (copy-file msvc-flags:vcx-proj-file msb-target-file t t))


        ;; create rsp file
        (unless (file-exists-p msb-rsp-file)
          (let* ((compile-file msvc-flags:compile-file)
                 (logger-vb-lv "diagnostic")
                 (diagnostic-file (concat (file-name-sans-extension log-file) "-" logger-vb-lv ".log"))
                 (logger-encoding "UTF-8")

                 (msb-flags (list
                             (msvc-env:create-msb-flags "/p:"
                                                        `(("ImportProjectFile=%S"   .       ,project-file)
                                                          ("Platform=%S"            .       ,platform)
                                                          ("Configuration=%S"       .       ,configuration)
                                                          ("CompileFile=%S"         .       ,compile-file)
                                                          ;; IntDir,OutDirは末尾にスラッシュが必須(MSBuildの仕様)
                                                          ("IntDir=%S"              .       ,db-path)
                                                          ("OutDir=%S"              .       ,db-path)))
                             (msvc-env:create-msb-flags "/flp:"
                                                        `(("Verbosity=%s"           .       "normal")
                                                          ("LogFile=%S"             .       ,log-file)
                                                          ("Encoding=%s"            .       ,logger-encoding)))
                             (msvc-env:create-msb-flags "/flp1:"
                                                        `(("Verbosity=%s"           .       ,logger-vb-lv)
                                                          ("LogFile=%S"             .       ,diagnostic-file)
                                                          ("Encoding=%s"            .       ,logger-encoding)))
                             "/noconsolelogger"
                             "/nologo")))

            (msvc-env:create-msb-rsp-file msb-rsp-file msb-target-file msb-flags)))

        ;; パースバッファはなければ作成、既存の場合は設定引継ぎとクリア
        (when (get-buffer-create process-bind-buffer)
          (with-current-buffer process-bind-buffer
            ;; バッファが既存の場合も考慮した設定を行う
            ;; リードオンリー解除
            (setq buffer-read-only nil)
            ;; パース後バッファ削除設定をローカル変数で引き継ぐ
            ;; for var current bind inherit
            (set (make-local-variable 'msvc-flags:parsing-buffer-delete-p) parsing-buffer-delete-p)
            ;; バッファクリア
            (erase-buffer)))


        ;; execute
        (if sync-p
            ;; sync
            (progn
              (when (eq (apply 'call-process command nil process-bind-buffer nil command-args) 0)
                (msvc-flags:regist-db db-name (msvc-flags:parse-compilation-buffer process-bind-buffer)))
              ;; parsing flag off
              (setq msvc-flags:parsing-p nil))
          ;; async
          (let ((process (apply 'start-process process-name process-bind-buffer command command-args)))
            (set-process-sentinel process 'msvc-flags:process-sentinel)))


        (cl-return-from msvc-flags:parse-vcx-project db-name)))))




(cl-defun msvc-flags:parse-vcx-solution (&rest args)
  "parse *.sln file : Microsoft Visual Studio
attributes
:solution-file
:platform
:configuration
:version

optionals
:parsing-buffer-delete-p
:force-parse-p
:sync-p
"

  (interactive)

  ;; product not detected MSVC
  (unless msvc-env:product-detected-p
    (message "msvc-flags : product not detected : Microsoft Visual Studio")
    (cl-return-from msvc-flags:parse-vcx-solution nil))

  ;; get property from args
  (let ((solution-file (plist-get args :solution-file)))

    ;; file extension check
    (unless (eq (compare-strings (file-name-extension solution-file) nil nil "sln" nil nil t) t)
      (message "msvc-flags : This file is not solution file. : %s" solution-file)
      (cl-return-from msvc-flags:parse-vcx-solution nil))

    ;; solution file exist check
    (unless (file-readable-p solution-file)
      (message "msvc-flags : Solution File Not Found. : %s" solution-file)
      (cl-return-from msvc-flags:parse-vcx-solution nil))

    (let* ((sln-directory (file-name-directory solution-file))
           (parse-buffer (format msvc-flags:process-buffer-name-fmt solution-file))
           (pattern "Project([^)]+)\\s-+=\\s-+\"\\([^\"]+\\)\"[^\"]+\"\\([^\"]+\\)\"")
           projects
           project-name
           project-path
           db-names)

      (when (get-buffer-create parse-buffer)
        (with-current-buffer parse-buffer
          ;; parse-bufferを該当ファイルで置き換える
          (insert-file-contents solution-file nil nil nil t)

          (goto-char (point-min))
          (while (re-search-forward pattern nil t)
            (setq project-name (match-string 1))
            (setq project-path (match-string 2))

            ;; パスのバックスラッシュ等は再置換
            (setq project-path (replace-regexp-in-string "[\\\\]+" "/" project-path))
            (setq project-path (expand-file-name project-path sln-directory))

            (when (file-readable-p project-path)
              (add-to-list 'projects project-path) t))
          (kill-buffer)))

      (cl-dolist (path projects)
        (let ((db-name (apply 'msvc-flags:parse-vcx-project :project-file path args)))
          (when db-name
            (add-to-list 'db-names db-name t))))

      (cl-return-from msvc-flags:parse-vcx-solution db-names))))


(cl-defun msvc-flags:load-db (&key
                            (parsing-buffer-delete-p nil)
                            (db-name-pattern nil))
  (interactive)
  
  ;; msvc-flags:db-root-path 以下にある全ての db をリロードして regist-db しなおす
  ;; 直下のディレクトリリストを foreach して directory-name を取り出す
  ;; name がそのまま db-name
  (let* ((msvc-flags:parsing-buffer-delete-p parsing-buffer-delete-p)
         (db-dirs (directory-files msvc-flags:db-root-path nil db-name-pattern t))
         (count 0))

    (cl-dolist (db-name db-dirs)
      (when (not (eq ?\. (aref db-name 0)))
        (msvc-flags:regist-db db-name (msvc-flags:parse-compilation-db db-name))
        (setq count (1+ count))))
    count))


(cl-defun msvc-flags:reparse-db (&key
                               (parsing-buffer-delete-p nil)
                               (db-name-pattern nil)
                               (force-parse-p nil)
                               (sync-p nil))
  (interactive)

  ;; リパースプロジェクト数が多い場合は遅延させないと、パイプエラーになる。
  ;; これどうしようか？
  ;; sentinel を利用していると変数をbindしても効果がない。
  ;; これは、bindスコープから脱した後に sentinel が動作するため。

  (let* (
         ;; (msvc-flags:parsing-buffer-delete-p parsing-buffer-delete-p)
         (db-dirs (directory-files msvc-flags:db-root-path nil db-name-pattern t))
         (count 0))

    (cl-dolist (db-name db-dirs)
      (when (not (eq ?\. (aref db-name 0)))
        (let* ((property (msvc-flags:create-project-property db-name))
               (project-file (plist-get property :project-file))
               (platform (plist-get property :platform))
               (configuration (plist-get property :configuration))
               (version (plist-get property :version)))

          (when (msvc-flags:parse-vcx-project :project-file project-file :platform platform :configuration configuration :version version :force-parse-p force-parse-p :sync-p sync-p :parsing-buffer-delete-p parsing-buffer-delete-p)
            (setq count (1+ count))))))
    count))


(defun msvc-flags:clear-variables ()
  (setq msvc-flags:cflags-db nil)
  (setq msvc-flags:parsing-buffer-delete-p nil))


(defun msvc-flags:initialize ()
  ;; create database root directory
  (unless (file-accessible-directory-p msvc-flags:db-root-path)
    (make-directory msvc-flags:db-root-path))
  t)


;; POSIX-style-path は Clang PCH を作成する際に重要(clang3.3)
;; 
;; 1. libclang のコンパイルプラットフォームによってスタイルを選択する必要がある
;; cygwinビルドであれば POSIX-style
;; Visual Studioビルドであれば Win32-style
;; ac-clang.el は Win32-style 想定
;; 
;; 2. PCH生成時に引数として与えるインクルードサーチパスは POSIX-style-path でなければならない
;; Clang のオプションで与えられるインクルードサーチパスは Win32-style でもPCH作成は可能
;; ただ、作成されたPCH内に格納されているパスが "/root/" + "Win32-style-path" になってしまう
;; Clang は "/" から始まっていない非POSIX-path-styleが与えられた場合 "/root/" を付加してPOSIX-pathにするルールがあるようだ
;; つまり "c:/Program" なら "/root/c:/Program" となる
;; これにより作成したPCHを -include-pch で渡しても補完などが正常に行われない
;; これを回避するためには POSIX-style-path にする必要があるため
;; "/cygdrive/" を path-prefix として持つ cygpath にコンバートする必要がある
;; c:/Program Files (x86)/  > /cygdrive/c/Program Files (x86)/
(defsubst msvc-flags:convert-to-clang-style-path (paths &optional safe-path)
  (when safe-path
    (setq paths (msvc-env:normalize-path paths safe-path)))

  (if (eq msvc-flags:clang-path-format 'posix)
      (msvc-env:convert-to-posix-style-path paths)
    paths))


;; utility
(defun msvc-flags:create-clang-cflags (db-name)
  (let* (clang-cflags
         (project-path (msvc-flags:create-project-path db-name))

         (system-ppdefs (msvc-flags:query-cflag db-name "CFLAG_SystemPreprocessorDefinitions"))
         (additional-ppdefs (msvc-flags:query-cflag db-name "CFLAG_AdditionalPreprocessorDefinitions"))
         (undef-ppdefs (msvc-flags:query-cflag db-name "CFLAG_UndefinePreprocessorDefinitions"))
         (system-inc-paths (msvc-flags:convert-to-clang-style-path (msvc-flags:query-cflag db-name "CFLAG_SystemIncludePath")))
         (additional-inc-paths (msvc-flags:convert-to-clang-style-path (msvc-flags:query-cflag db-name "CFLAG_AdditionalIncludePath") project-path))
         (exclude-inc-paths (msvc-flags:convert-to-clang-style-path (msvc-flags:query-cflag db-name "CFLAG_ExcludePath")))
         (force-inc-files (msvc-flags:convert-to-clang-style-path (msvc-flags:query-cflag db-name "CFLAG_ForceIncludeFiles")))
         ;; (target-cpp-files (msvc-flags:convert-to-clang-style-path (msvc-flags:query-cflag db-name "CFLAG_TargetSourceFiles")))
         ;; (target-hpp-files (msvc-flags:convert-to-clang-style-path (msvc-flags:query-cflag db-name "CFLAG_TargetHeaderFiles")))

         (opt-msc-extensions-disable (car (msvc-flags:query-cflag db-name "ClCompile.DisableLanguageExtensions")))
         (opt-exception-handling-enable (car (msvc-flags:query-cflag db-name "ClCompile.ExceptionHandling")))
         (opt-rtti-enable (car (msvc-flags:query-cflag db-name "ClCompile.RuntimeTypeInfo")))
         (opt-compile-as (car (msvc-flags:query-cflag db-name "ClCompile.CompileAs")))
         (opt-pch-enable (car (msvc-flags:query-cflag db-name "ClCompile.PrecompiledHeader")))
         (opt-pch-file (car (msvc-flags:query-cflag db-name "ClCompile.PrecompiledHeaderFile")))
         )

    (when (and opt-msc-extensions-disable (string-match "false" opt-msc-extensions-disable))
      (setq clang-cflags (append clang-cflags '("-fms-compatibility" "-fms-extensions" "-fmsc-version=1600"))))
    (unless (and opt-exception-handling-enable (string-match "false" opt-exception-handling-enable))
      (add-to-list 'clang-cflags "-fcxx-exceptions" t))
    (when (and opt-rtti-enable (string-match "false" opt-rtti-enable))
      (add-to-list 'clang-cflags "-fno-rtti" t))

    ;; (unless (and opt-pch-enable (string-match "NotUsing" opt-pch-enable))
    ;;   (when opt-pch-file
    ;;  (add-to-list 'clang-cflags (format "-include-pch %s" opt-pch-file) t)
    ;;  )
    ;;   )

    ;; clangと libclang では -isystem の受け取り方が異なるぽい
    ;; command line 時は "-isystem" "path" の２引数でないとだめで
    ;; libclang への指定は "-isystem path" でないと正常動作しない。
    ;; ※動くがinclude path searchの挙動がおかしい

    ;; -isystem <directory>    Add directory to SYSTEM include search path
    ;; -I <directory>          Add directory to include search path
    (cl-dolist (path system-inc-paths)
      ;; (unless (assoc-string path exclude-inc-paths)
      (add-to-list 'clang-cflags (format "-I%s" path) t)
      ;; (add-to-list 'clang-cflags (format "-isystem %s" path) t)
      ;; (add-to-list 'clang-cflags (format "-cxx-isystem %s" path) t)
      ;; )
      )
    ;; -I <directory>          Add directory to include search path
    (cl-dolist (path additional-inc-paths)
      ;; (unless (assoc-string path exclude-inc-paths)
      (add-to-list 'clang-cflags (format "-I%s" path) t)
      ;; )
      )
    ;; -include <file>         Include file before parsing
    (cl-dolist (file force-inc-files)
      (add-to-list 'clang-cflags (format "-include %s" file) t))

    ;; -D <macro>              Predefine the specified macro
    (cl-dolist (def system-ppdefs)
      (add-to-list 'clang-cflags (format "-D %s" def) t))
    ;; -D <macro>              Predefine the specified macro
    (cl-dolist (def additional-ppdefs)
      (add-to-list 'clang-cflags (format "-D %s" def) t))
    ;; -U <macro>              Undefine the specified macro
    (cl-dolist (def undef-ppdefs)
      (add-to-list 'clang-cflags (format "-U %s" def) t))

    clang-cflags))


(defun msvc-flags:create-ac-clang-cflags (db-name &optional additional-options)
  (interactive)

  (let* ((default-options '(
                            "-std=c++11"
                            ;; libclang3.1 は↓の渡し方しないとだめ(3.2/3.3は未調査)
                            ;; -no*inc系オプションを個別に渡すと include サーチの動作がおかしくなる
                            ;; -isystem で正常なパスを渡していても Windows.h は見に行けるが、 stdio.h vector などを見に行っていないなど

                            ;; なんか -x c++ だと -nostdinc だめ？とりあえず外しておく(Clang3.3)
                            ;; "-nobuiltininc -nostdinc -nostdinc++ -nostdsysteminc"
                            ;; "-nobuiltininc -nostdinc++ -nostdsysteminc"
                            "-nobuiltininc" "-nostdinc++" "-nostdsysteminc"
                            "-code-completion-macros" "-code-completion-patterns"
                            "-fdelayed-template-parsing"
                            "-Wno-unused-value" "-Wno-#warnings" "-Wno-microsoft" "-Wc++11-extensions"
                            ;; undef all system defines
                            "-target-cpu x86-64"
                            "-triple x86_64-pc-win32"
                            ))
         (db-clang-cflags (msvc-flags:create-clang-cflags db-name))
         (clang-cflags (append default-options db-clang-cflags additional-options)))

    clang-cflags))


(defun msvc-flags:create-ac-clang-pch (db-name input-pch output-pch &optional additional-options)
  (interactive)

  (let* ((default-options `(
                            ;; -emit-pch               Generate pre-compiled header file
                            "-cc1" "-x" "c++-header" "-emit-pch"

                            "-std=c++11"
                            ;; なんか -nostdinc だめなので外しておく(Clang3.1)
                            ;; "-nobuiltininc" "-nostdinc" "-nostdinc++" "-nostdsysteminc"
                            "-nobuiltininc" "-nostdinc++" "-nostdsysteminc"
                            "-code-completion-macros" "-code-completion-patterns"
                            "-fdelayed-template-parsing"
                            "-Wno-unused-value" "-Wno-#warnings" "-Wno-microsoft" "-Wc++11-extensions"
                            ;; undef all system defines
                            ;; "-undef"
                            ;; x64,x86のときに undefすべき項目をまとめておく、本来は -undef すればおｋなのだがclang が落ちるため(3.3 msvc64では落ちなかった)
                            ;; "-U _X86_" "-U __SIZE_TYPE__"
                            "-o" ,output-pch
                            ))
         (db-clang-cflags (msvc-flags:create-clang-cflags db-name))
         (clang-cflags (append default-options db-clang-cflags additional-options `(,input-pch))))
    
    (apply 'start-process "clang" "*Clang PCH-Log*" "clang" clang-cflags)
    clang-cflags))






(provide 'msvc-flags)
;;--------------------------------------------------------------------------------------------------
;; EOF
