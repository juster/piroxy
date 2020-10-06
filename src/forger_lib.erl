%%% forger_lib
%%% Forges certificates from other hosts so that we can place a
%%% man-in-the-middle to eavesdrop on TLS streams. This requires
%%% that we also create our own self-signed certificate.

-module(forger_lib).
-include_lib("public_key/include/public_key.hrl").
-import(public_key, [generate_key/1, pem_entry_encode/3, pem_encode/1,
                     pem_entry_decode/1, pem_entry_decode/2, pem_decode/1,
                     pkix_sign/2]).
-import(lists, [map/2]).
-define(ISSUER_CN, "Pirate Proxy Root CA").
-define(ISSUER_ORG, "Piroxy Dev Team").
-define(ISSUER_CO, "US").

%% References:
%% RFC5280: has the relevant ASN1 information
%% RFC5480: info specific to using elliptic curve with PKI, for example:
%%
%% Minimum  | ECDSA    | Message    | Curves
%% Bits of  | Key Size | Digest     |
%% Security |          | Algorithms |
%% ---------+----------+------------+-----------
%% ...      |          |            |
%% 256      | 512      | SHA-512    | secp521r1
%%
%% This module is hard-coded to use the secp521r1 curve.

-export([generate_ca_pair/1, decode_ca_pair/2, forge/2]).

%%%
%%% EXPORTS
%%%

%% Returns a PEM-encoded binary with a Certificate entry and ECPrivateKey entry.
%% The ECPrivateKey entry is encrypted with the provided Passwd.
generate_ca_pair(Passwd) ->
    PriKey = generate_key({namedCurve,secp521r1}),
    PubKey = PriKey#'ECPrivateKey'.publicKey,
    CertDer = ecc_certificate(issuer(), PubKey, PriKey, authority),
    CipherInfo = {"DES-CBC", crypto:strong_rand_bytes(8)},
    PriKeyEnt = pem_entry_encode('ECPrivateKey', PriKey, {CipherInfo, Passwd}),
    %%PriKeyPem = pem_encode([PriKeyEnt]),
    pem_encode([{'Certificate',CertDer,not_encrypted}, PriKeyEnt]).

%% Decode the certificate PEM which contains a ECPrivateKey entry
%% Decrypt this entry, which requires the password given to generate_ca_pair.
decode_ca_pair(PriPem, Passwd) ->
    [Cert, PriEntry] = pem_decode(PriPem),
    {pem_entry_decode(Cert), pem_entry_decode(PriEntry, Passwd)}.

%% Create a new cert/private key for the given host name/ip number.
%% FQDNs = [binary()]
forge(FQDNs, CAPriKey) ->
    [Hd|_] = FQDNs,
    Contact = [{?'id-at-commonName', Hd}],
    PriKey = generate_key({namedCurve,secp521r1}),
    PubKey = PriKey#'ECPrivateKey'.publicKey,
    CertDer = ecc_certificate(Contact, PubKey, CAPriKey, {host,FQDNs}),
    {CertDer,PriKey}.

%%%
%%% INTERNAL
%%%

timefmt({Y,Mo,D},{H,Mi,S}) ->
    io_lib:format("~2..0B~2..0B~2..0B~2..0B~2..0B~2..0BZ", [Y rem 100,Mo,D,H,Mi,S]).

validity() ->
    {{Y,M,D},Time} = calendar:universal_time(),
    #'Validity'{
       notBefore = {utcTime,timefmt({Y,M,D},Time)},
       notAfter = {utcTime,timefmt({Y+1,M,D},Time)}
      }.

keyIdentifier(KeyBin) ->
    crypto:hash(sha, KeyBin).

randSerial() ->
    <<Serial:160/integer>> = crypto:strong_rand_bytes(20),
    Serial.

attributes(L) ->
    %% don't forget each attribute is wrapped in a list for some reason
    Fun = fun ({T,V}) when is_binary(V) ->
                  [#'AttributeTypeAndValue'{type=T,value={utf8String,V}}];
              ({T,V}) ->
                  [#'AttributeTypeAndValue'{type=T,value=V}]
          end,
    {rdnSequence, map(Fun, L)}.

issuer() ->
    [{?'id-at-commonName',<<?ISSUER_CN>>},
     {?'id-at-organizationName',<<?ISSUER_ORG>>},
     {?'id-at-countryName',"us"}].

%% all extensions are critical
extension_records(L) -> [#'Extension'{extnID=Oid, critical=true, extnValue=V}
                         || {Oid,V} <- L].

ecc_certificate(Subject0, SubjectPubKey, CaPriKey, Purpose) ->
    Subject = attributes(Subject0), % checks arguments early
    PubKeyInfo = #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{
            algorithm = ?'id-ecPublicKey',
            parameters = {namedCurve, ?'secp521r1'}
        },
        subjectPublicKey = #'ECPoint'{point=SubjectPubKey}
    },
    Extensions = [
        {?'id-ce-subjectKeyIdentifier',false,keyIdentifier(SubjectPubKey)}|
        case Purpose of
        authority -> [
            {?'id-ce-basicConstraints',
             #'BasicConstraints'{cA=true, pathLenConstraint=asn1_NOVALUE}},
            {?'id-ce-keyUsage',[digitalSignature,keyCertSign,cRLSign]}
        ];
        {host,DNSNames} -> [
            {?'id-ce-basicConstraints',
             #'BasicConstraints'{cA=false, pathLenConstraint=asn1_NOVALUE}},
            {?'id-ce-keyUsage',[keyEncipherment,keyAgreement]},
            {?'id-ce-extKeyUsage',[?'id-kp-serverAuth']},
            {?'id-ce-subjectAltName',[{'dNSName',N} || N <- DNSNames]}
        ];
        _ -> exit(badarg)
        end
    ],
    SignatureAlgorithm = #'SignatureAlgorithm'{
        algorithm = ?'ecdsa-with-SHA512',
        parameters = {namedCurve, ?'secp521r1'}
    },
    TBSCertificate = #'OTPTBSCertificate'{
        version = v3,
        serialNumber = randSerial(),
        signature = SignatureAlgorithm,
        issuer = attributes(issuer()),
        validity = validity(),
        subject = Subject,
        subjectPublicKeyInfo = PubKeyInfo,
        issuerUniqueID = asn1_NOVALUE,
        subjectUniqueID = asn1_NOVALUE,
        extensions = extension_records(Extensions)
    },
    pkix_sign(TBSCertificate, CaPriKey).
