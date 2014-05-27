open Lwt
open V1_LWT


module Color = struct
  open Printf
  let red    fmt = sprintf ("\027[31m"^^fmt^^"\027[m")
  let green  fmt = sprintf ("\027[32m"^^fmt^^"\027[m")
  let yellow fmt = sprintf ("\027[33m"^^fmt^^"\027[m")
  let blue   fmt = sprintf ("\027[36m"^^fmt^^"\027[m")
end

module Cs  = Tls.Utils.Cs

let o f g x = f (g x)

let lower exn_of_err f =
  f >>= function | `Ok r    -> return r
                 | `Error e -> fail (exn_of_err e)

let string_of_err = function
  | `Timeout     -> "TIMEOUT"
  | `Refused     -> "REFUSED"
  | `Unknown msg -> msg


module Log (C: CONSOLE) = struct

  let log_trace c str = C.log_s c (Color.green "+ %s" str)

  and log_data c str buf =
    let repr = String.escaped (Cstruct.to_string buf) in
    C.log_s c (Color.blue "  %s: " str ^ repr)
  and log_error c e = C.log_s c (Color.red "+ err: %s" (string_of_err e))

end

module Mir_X509 (Kv: KV_RO) = struct

  let (>>==) a f =
    a >>= function
      | `Ok x -> f x
      | `Error (Kv.Unknown_key key) -> fail (Invalid_argument key)

  let (>|==) a f = a >>== fun x -> return (f x)

  let read_full kv ~name =
    Kv.size kv name   >|== Int64.to_int >>=
    Kv.read kv name 0 >|== Cs.appends

  open Tls.X509

  let certificate kv ~cert ~key =
    lwt cert = read_full kv cert >|= Cert.of_pem_cstruct1
    and key  = read_full kv key  >|= PK.of_pem_cstruct1 in
    return (cert, key)

  let ca_roots kv ~cas =
    read_full kv cas
    >|= Cert.of_pem_cstruct
    >|= Validator.chain_of_trust ~time:0

end

module Server (C: CONSOLE) (S: STACKV4) (Kv: KV_RO) = struct

  module TLS  = Tls_mirage.Make (S.TCPV4)
  module X509 = Mir_X509 (Kv)
  module L    = Log (C)

  let rec handle c tls =
    TLS.read tls >>= function
    | `Eof     -> L.log_trace c "eof."
    | `Error e -> L.log_error c e
    | `Ok buf  -> L.log_data c "recv" buf >> TLS.write tls buf >> handle c tls

  let accept c cert k flow =
    L.log_trace c "accepted." >>
    TLS.server_of_tcp_flow cert flow >>= function
      | `Ok tls  -> L.log_trace c "shook hands" >> k c tls
      | `Error e -> L.log_error c e

  let start c stack kv =
    lwt cert =
      X509.certificate kv ~cert:"server.pem" ~key:"server.key" in
    S.listen_tcpv4 stack 4433 (accept c cert handle) ;
    S.listen stack

end

module Client (C: CONSOLE) (S: STACKV4) (Kv: KV_RO) = struct

  module TLS  = Tls_mirage.Make (S.TCPV4)
  module X509 = Mir_X509 (Kv)
  module L    = Log (C)

  open Ipaddr

  let peer = ((V4.of_string_exn "127.0.0.1", 4433), "localhost")
  let peer = ((V4.of_string_exn "173.194.70.147", 443), "www.google.com")

  let chat c tls =
    let rec dump () =
      TLS.read tls >>= function
        | `Error e -> L.log_error c e
        | `Eof     -> L.log_trace c "eof."
        | `Ok buf  -> L.log_data  c "reply" buf >> dump ()
    in
    TLS.write tls (Cstruct.of_string "ohai\r\n\r\n") >> dump ()

  let start c stack kv =
    lwt validator = X509.ca_roots kv ~cas:"ca-root-nss-short.crt" in
    TLS.create_connection (S.tcpv4 stack)
      (None, validator) (snd peer) (fst peer)
    >>= function
      | `Ok tls  -> L.log_trace c "connected." >> chat c tls
      | `Error e -> L.log_error c e

end