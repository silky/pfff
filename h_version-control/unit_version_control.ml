open Common

open OUnit
module Lib = Lib_vcs

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)
let with_tmp_directory f =
  let tmp_dir = Filename.temp_file (spf "vcs-test-%d" (Unix.getpid())) "" in
  Unix.unlink tmp_dir;
  (* who cares about race *)
  Unix.mkdir tmp_dir 0o755;
  Common.finalize (fun () ->
    f tmp_dir
  )
    (fun () ->
      (* yep, rm -rf, I'm not scared *)
      Common.command2 (spf "rm -rf %s/.git" tmp_dir);
      Common.command2 (spf "rm -rf %s/.hg" tmp_dir);
      Common.command2 (spf "rm -f %s/*" tmp_dir);
      Unix.rmdir tmp_dir
    )

let exec_cmds ~basedir xs =
  xs +> List.iter (fun cmd ->
    let exit_status = Sys.command (spf "cd %s; %s" basedir cmd) in
    match exit_status with
    | 0 -> ()
    | _ -> 
      failwith (spf "command '%s' failed, exit code = %d" cmd exit_status)
  )

(*****************************************************************************)
(* Unit tests *)
(*****************************************************************************)

let unittest =
  "version_control" >::: [

(*****************************************************************************)
(* Basic *)
(*****************************************************************************)

    "find root" >:: (fun () ->
      let pfff_home = Config_pfff.path in
      try
        assert_equal
          (Git.find_root_from_absolute_path pfff_home)
          pfff_home;
        assert_equal
          (Git.find_root_from_absolute_path (pfff_home ^ "/"))
          pfff_home;
        assert_equal
          (Git.find_root_from_absolute_path
             (pfff_home ^ "/h_version-control/unit_version_control.ml"))
          pfff_home;
        assert_raises Not_found
          (fun () -> Git.find_root_from_absolute_path "/");
      with Not_found ->
        assert_failure "fail to find root for pfff_home";
    );

    "parsing file status" >:: (fun () ->
      assert_equal
        (Lib.Added, "a/b/foo.php")
        (Lib.parse_file_status "A\ta/b/foo.php");

      assert_equal
        (Lib.Renamed (99, "a/b/foo.php"), "a/c/bar.php")
        (Lib.parse_file_status "R099\ta/b/foo.php\ta/c/bar.php");

    );

(*****************************************************************************)
(* Git *)
(*****************************************************************************)

    "git" >:: (fun () ->
       with_tmp_directory (fun basedir ->
         Flag_version_control.verbose := false;

         exec_cmds ~basedir [
           "git init > /dev/null";
           "echo 'foo' > foo.txt";
           "echo 'bar' > bar.txt";
           "git add bar.txt foo.txt";
           "git commit -m 'first commit' > /dev/null";
         ];
         let commit_id = Lib.VersionId "HEAD" in
         let previous_id = Lib.VersionId "HEAD^" in

         let xs =
           Git.files_involved_in_diff ~basedir commit_id in
         assert_equal 
           ~msg:"it should find all added files in a diff"
           [Lib.Added, "bar.txt"; Lib.Added, "foo.txt"]
           (Common.sort xs);

         let xs = 
           Git.grep ~basedir "ba" in
         assert_equal
           ~msg:"it should find files containing ba with git grep"
           ["bar.txt"]
           xs;

         exec_cmds ~basedir [
           "echo new_content > bar.txt";
           "git commit -a -m'first modif' > /dev/null";
         ];

         let tmpfile =
           Git.show ~basedir "bar.txt" commit_id in
         let xs = Common.cat tmpfile in
         assert_equal
           ~msg:"it should show the current content of the file"
           ["new_content"]
           xs;
         let tmpfile =
           Git.show ~basedir "bar.txt" previous_id in
         let xs = Common.cat tmpfile in
         assert_equal
           ~msg:"it should show the past content of the file"
           ["bar"]
           xs;

       );
    );

(*****************************************************************************)
(* Mercurial *)
(*****************************************************************************)
    "mercurial" >:: (fun () ->
       with_tmp_directory (fun basedir ->
         Flag_version_control.verbose := false;

         exec_cmds ~basedir [
           "hg init > /dev/null";
           "echo 'foo' > foo.txt";
           "echo 'bar' > bar.txt";
           "hg add bar.txt foo.txt";
           "hg commit -m 'first commit' > /dev/null";
         ];
         let _commit_id = Lib.VersionId "HEAD" in
         let _previous_id = Lib.VersionId "HEAD^" in

         let xs = 
           Mercurial.grep ~basedir "ba" in
         assert_equal
           ~msg:"it should find files containing ba with hg grep"
           ["bar.txt"]
           xs;

       )
    );
  ]
