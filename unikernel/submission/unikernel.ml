open Rresult
open Lwt.Infix

let ( >>? ) = Lwt_result.bind
let ( <.> ) f g = fun x -> f (g x)

module Maker = Irmin_mirage_git.KV (Irmin_git.Mem)
module Store = Maker.Make (Ptt_irmin)
module Sync = Irmin.Sync.Make (Store)

let failwith_error_pull = function
  | Error (`Conflict err) -> Fmt.failwith "Conflict: %s" err
  | Error (`Msg err) -> failwith err
  | Ok v -> v

let local_to_string local =
  let pp ppf = function `Atom x -> Fmt.string ppf x
    | `String v -> Fmt.pf ppf "%S" v in
  Fmt.str "%a" Fmt.(list ~sep:(any ".") pp) local

module Make
  (Random : Mirage_random.S)
  (Time : Mirage_time.S)
  (Mclock : Mirage_clock.MCLOCK)
  (Pclock : Mirage_clock.PCLOCK)
  (Stack : Mirage_stack.V4V6)
  (_ : sig end)
= struct
  module Nss = Ca_certs_nss.Make (Pclock)
  module Paf = Paf_mirage.Make (Time) (Stack)
  module LE = LE.Make (Time) (Stack)

  (* XXX(dinosaure): this is a fake resolver which enforce the [submission] to
   * transmit **any** emails to only one and unique SMTP server. *)

  module Resolver = struct
    type t = Ipaddr.V4.t
    type +'a io = 'a Lwt.t

    let gethostbyname ipaddr _domain_name = Lwt.return_ok ipaddr
    let getmxbyname _ipaddr mail_exchange = Lwt.return_ok (Dns.Rr_map.Mx_set.singleton { Dns.Mx.preference= 0; mail_exchange; })
    let extension ipaddr _ldh _value = Lwt.return_ok ipaddr
  end

  module Lipap = Lipap.Make (Random) (Time) (Mclock) (Pclock) (Resolver) (Stack)

  let authentication ctx remote =
    let tree = Art.make () in
    let config = Irmin_mem.config () in
    Store.Repo.v config >>= Store.master >>= fun store ->
    let upstream = Store.remote ~ctx remote in
    Sync.pull store upstream `Set
    >|= failwith_error_pull
    >>= fun _ ->
    Store.(list store (Schema.Path.v [])) >>= fun values ->
    let f () (name, k) = match Store.Tree.destruct k with
      | `Node _ -> Lwt.return_unit
      | `Contents _ ->
        Store.(get store (Schema.Path.v [ name ])) >>= fun { Ptt_irmin.password; _ } ->
        let local = Art.key name in
        Art.insert tree local password ; Lwt.return_unit in
    Lwt_list.fold_left_s f () values >>= fun () ->
    let authentication local v' =
      match Art.find tree (Art.key (local_to_string local)) with
      | v -> Lwt.return (Digestif.equal Digestif.BLAKE2B (Digestif.of_blake2b v) v')
      | exception _ -> Lwt.return false in
    let authentication =
      let open Ptt_tuyau.Lwt_backend.Lwt_scheduler in
      Ptt.Authentication.v
        (fun local v -> inj (authentication local v)) in
    Lwt.return authentication

  let ignore_error _ ?request:_ _ _ = ()

  let certificate stackv4v6 =
    match Key_gen.cert_der (), Key_gen.cert_key (),
          Key_gen.hostname () with
    | Some cert_der, Some cert_key, _ ->
      let open Rresult in
      let res =
        Base64.decode cert_der |> R.reword_error (fun _ -> R.msgf "Invalid DER certificate")
        >>| Cstruct.of_string >>= X509.Certificate.decode_der >>= fun certificate ->
        Base64.decode cert_key |> R.reword_error (fun _ -> R.msgf "Invalid private key")
        >>| Cstruct.of_string >>= fun seed -> R.ok (certificate, seed) in
      Lwt.return res >>? fun (certificate, seed) ->
      let g = Mirage_crypto_rng.(create ~seed (module Fortuna)) in
      let private_key = Mirage_crypto_pk.Rsa.generate ~g ~bits:2048 () in
      Lwt.return_ok (`Single ([ certificate ], `RSA private_key))
    | _, _, Some hostname ->
      let module DNS = Dns_client_mirage.Make (Random) (Time) (Mclock) (Stack) in
      Lwt.return Rresult.(Domain_name.of_string hostname >>= Domain_name.host) >>? fun hostname ->
      Paf.init ~port:80 stackv4v6 >>= fun t ->
      let service = Paf.http_service ~error_handler:ignore_error LE.request_handler in
      let stop = Lwt_switch.create () in
      let `Initialized th0 = Paf.serve ~stop service t in
      let th1 =
        LE.provision_certificate
          ~production:(Key_gen.production ())
          { LE.certificate_seed= Key_gen.cert_seed ()
          ; LE.certificate_key_type= `ED25519
          ; LE.certificate_key_bits= None
          ; LE.email= Option.bind (Key_gen.email ()) (R.to_option <.> Emile.of_string)
          ; LE.account_seed= Key_gen.account_seed ()
          ; LE.account_key_type= `ED25519
          ; LE.account_key_bits= None
          ; LE.hostname= hostname }
          (LE.ctx
            ~gethostbyname:(fun dns domain_name -> DNS.gethostbyname dns domain_name >>? fun ipv4 -> Lwt.return_ok (Ipaddr.V4 ipv4))
            ~authenticator:(R.failwith_error_msg (Nss.authenticator ()))
            (DNS.create stackv4v6) stackv4v6) >>= fun res ->
          Lwt_switch.turn_off stop >>= fun () -> Lwt.return res in
      Lwt.both th0 th1 >>= fun ((), v) -> Lwt.return v

  let time () = match Ptime.v (Pclock.now_d_ps ()) with
    | v -> Some v | exception _ -> None

  let parse_alg str = match String.lowercase_ascii str with
    | "sha1" -> Ok `SHA1
    | "sha256" -> Ok `SHA256
    | _ -> R.error_msgf "Invalid hash algorithm: %S" str

  let authenticator () = match Key_gen.key_fingerprint (), Key_gen.cert_fingerprint () with
    | None, None -> Nss.authenticator ()
    | Some str, _ ->
      let res = match String.split_on_char ':' str with
        | [ host; alg; fingerprint ] ->
          let open Rresult in
          Domain_name.of_string host >>= Domain_name.host >>= fun host ->
          parse_alg alg >>= fun alg ->
          Base64.decode ~pad:false fingerprint >>= fun fingerprint ->
          R.ok (host, alg, fingerprint)
        | _ -> R.error_msgf "Invalid key fingerprint." in
      let (_host, hash, fingerprint) = R.failwith_error_msg res in
      R.ok @@ X509.Authenticator.server_key_fingerprint ~time ~hash ~fingerprint:(Cstruct.of_string fingerprint)
    | None, Some str ->
      let res = match String.split_on_char ':' str with
        | [ host; alg; fingerprint ] ->
          let open Rresult in
          Domain_name.of_string host >>= Domain_name.host >>= fun host ->
          parse_alg alg >>= fun alg ->
          Base64.decode ~pad:false fingerprint >>= fun fingerprint ->
          R.ok (host, alg, fingerprint)
        | _ -> R.error_msgf "Invalid key fingerprint." in
      let (_host, hash, fingerprint) = R.failwith_error_msg res in
      R.ok @@ X509.Authenticator.server_cert_fingerprint ~time ~hash ~fingerprint:(Cstruct.of_string fingerprint)

  let start _random _time _mclock _pclock stack ctx =
    let domain = R.failwith_error_msg (Domain_name.of_string (Key_gen.domain ())) in
    let domain = Domain_name.host_exn domain in
    let postmaster =
      let postmaster = Key_gen.postmaster () in
      R.failwith_error_msg (R.reword_error (fun _ -> R.msgf "Invalid postmaster email: %S" postmaster)
        (Emile.of_string postmaster)) in
    let authenticator = R.failwith_error_msg (authenticator ()) in
    let tls = Tls.Config.client ~authenticator () in
    certificate stack >|= R.failwith_error_msg >>= fun certificates ->
    authentication ctx (Key_gen.remote ()) >>= fun authentication ->
    Lipap.fiber ~port:465 ~tls stack (Key_gen.destination ()) None Digestif.BLAKE2B
      (Ptt.Relay_map.empty ~postmaster ~domain)
      { Ptt.Logic.domain
      ; ipv4= (Ipaddr.V4.Prefix.address (Key_gen.ipv4 ()))
      ; tls= Tls.Config.server ~certificates ()
      ; zone= Mrmime.Date.Zone.GMT (* XXX(dinosaure): any MirageOS use GMT. *)
      ; size= 10_000_000L (* 10M *) }
      authentication [ Ptt.Mechanism.PLAIN ]
end
