(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2019       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

type compilation_mode = BuildVo | BuildVio | Vio2Vo

type t =
  { compilation_mode : compilation_mode

  ; compile_list: (string * bool) list  (* bool is verbosity  *)
  ; compilation_output_name : string option

  ; vio_checking : bool
  ; vio_tasks    : (int list * string) list
  ; vio_files    : string list
  ; vio_files_j  : int

  ; echo : bool

  ; outputstate : string option
  ; glob_out    : Dumpglob.glob_output
  }

let default =
  { compilation_mode = BuildVo

  ; compile_list = []
  ; compilation_output_name = None

  ; vio_checking = false
  ; vio_tasks    = []
  ; vio_files    = []
  ; vio_files_j  = 0

  ; echo = false

  ; outputstate = None
  ; glob_out = Dumpglob.MultFiles
  }

let depr opt =
  Feedback.msg_warning Pp.(seq[str "Option "; str opt; str " is a noop and deprecated"])

(* XXX Remove this duplication with Coqargs *)
let fatal_error exn =
  Topfmt.(in_phase ~phase:ParsingCommandLine print_err_exn exn);
  let exit_code = if (CErrors.is_anomaly exn) then 129 else 1 in
  exit exit_code

let error_missing_arg s =
  prerr_endline ("Error: extra argument expected after option "^s);
  prerr_endline "See -help for the syntax of supported options";
  exit 1

let check_compilation_output_name_consistency args =
  match args.compilation_output_name, args.compile_list with
  | Some _, _::_::_ ->
    prerr_endline ("Error: option -o is not valid when more than one");
    prerr_endline ("file have to be compiled")
  | _ -> ()

let is_dash_argument s = String.length s > 0 && s.[0] = '-'

let add_compile ?echo copts s =
  if is_dash_argument s then (prerr_endline ("Unknown option " ^ s); exit 1);
  (* make the file name explicit; needed not to break up Coq loadpath stuff. *)
  let echo = Option.default copts.echo echo in
  let s =
    let open Filename in
    if is_implicit s
    then concat current_dir_name s
    else s
  in
  { copts with compile_list = (s,echo) :: copts.compile_list }

let add_vio_task opts f =
  { opts with vio_tasks = f :: opts.vio_tasks }

let add_vio_file opts f =
  { opts with vio_files = f :: opts.vio_files }

let set_vio_checking_j opts opt j =
  try { opts with vio_files_j = int_of_string j }
  with Failure _ ->
    prerr_endline ("The first argument of " ^ opt ^ " must the number");
    prerr_endline "of concurrent workers to be used (a positive integer).";
    prerr_endline "Makefiles generated by coq_makefile should be called";
    prerr_endline "setting the J variable like in 'make vio2vo J=3'";
    exit 1

let set_compilation_mode opts mode =
  match opts.compilation_mode with
  | BuildVo -> { opts with compilation_mode = mode }
  | mode' when mode <> mode' ->
    prerr_endline "Options -quick and -vio2vo are exclusive";
    exit 1
  | _ -> opts

let get_task_list s =
  List.map (fun s ->
      try int_of_string s
      with Failure _ ->
        prerr_endline "Option -check-vio-tasks expects a comma-separated list";
        prerr_endline "of integers followed by a list of files";
        exit 1)
    (Str.split (Str.regexp ",") s)

let is_not_dash_option = function
  | Some f when String.length f > 0 && f.[0] <> '-' -> true
  | _ -> false

let rec add_vio_args peek next oval =
  if is_not_dash_option (peek ()) then
    let oval = add_vio_file oval (next ()) in
    add_vio_args peek next oval
  else oval

let warn_deprecated_outputstate =
  CWarnings.create ~name:"deprecated-outputstate" ~category:"deprecated"
         (fun () ->
          Pp.strbrk "The outputstate option is deprecated and discouraged.")

let set_outputstate opts s =
  warn_deprecated_outputstate ();
  { opts with outputstate = Some s }

let parse arglist : t =
  let echo = ref false in
  let args = ref arglist in
  let extras = ref [] in
  let rec parse (oval : t) = match !args with
    | [] ->
      (oval, List.rev !extras)
    | opt :: rem ->
      args := rem;
      let next () = match !args with
        | x::rem -> args := rem; x
        | [] -> error_missing_arg opt
      in
      let peek_next () = match !args with
        | x::_ -> Some x
        | [] -> None
      in
      let noval : t = begin match opt with
        (* Deprecated options *)
        | "-opt"
        | "-byte" as opt ->
          depr opt;
          oval
        | "-image" as opt ->
          depr opt;
          let _ = next () in
          oval
        (* Verbose == echo mode *)
        | "-verbose" ->
          echo := true;
          oval
        (* Output filename *)
        | "-o" ->
          { oval with compilation_output_name = Some (next ()) }
        | "-quick" ->
          set_compilation_mode oval BuildVio
        | "-check-vio-tasks" ->
          let tno = get_task_list (next ()) in
          let tfile = next () in
          add_vio_task oval (tno,tfile)

        | "-schedule-vio-checking" ->
          let oval = { oval with vio_checking = true } in
          let oval = set_vio_checking_j oval opt (next ()) in
          let oval = add_vio_file oval (next ()) in
          add_vio_args peek_next next oval

        | "-schedule-vio2vo" ->
          let oval = set_vio_checking_j oval opt (next ()) in
          let oval = add_vio_file oval (next ()) in
          add_vio_args peek_next next oval

        | "-vio2vo" ->
          let oval = add_compile ~echo:false oval (next ()) in
          set_compilation_mode oval Vio2Vo

        | "-outputstate" ->
          set_outputstate oval (next ())

        (* Glob options *)
        |"-no-glob" | "-noglob" ->
          { oval with glob_out = Dumpglob.NoGlob }

        |"-dump-glob" ->
          let file = next () in
          { oval with glob_out = Dumpglob.File file }

        (* Rest *)
        | s ->
          extras := s :: !extras;
          oval
      end in
      parse noval
  in
  try
    let opts, extra = parse default in
    let args = List.fold_left add_compile opts extra in
    check_compilation_output_name_consistency args;
    args
  with any -> fatal_error any

let parse args =
  let opts = parse args in
  { opts with
    compile_list = List.rev opts.compile_list
  ; vio_tasks = List.rev opts.vio_tasks
  ; vio_files = List.rev opts.vio_files
  }
