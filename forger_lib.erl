%%% forger_lib
%%% Forges certificates from other hosts so that we can place a
%%% man-in-the-middle to eavesdrop on TLS streams. This requires
%%% that we also create our own self-signed certificate.

-module(forger_lib).
-include_lib("public_key/include/public_key.hrl").
-import(public_key, [pem_entry_encode/2, pem_encode/1]).
-define(ISSUER_CN, "Pirate Proxy Root CA").
-define(ISSUER_ORG, "Piroxy Dev Team").
-define(ISSUER_CO, "US").

%% References:
%% RFC5280: has the relevant ASN1 information
%% RFC5480: info specific to using elliptic curve with PKI
%%
%% Minimum  | ECDSA    | Message    | Curves
%% Bits of  | Key Size | Digest     |
%% Security |          | Algorithms |
%% ---------+----------+------------+-----------
%% 256      | 512      | SHA-512    | secp521r1
%%
%% This module is hard-coded to use the secp521r1 curve.

-export([write_new/2, load/2, forge/2]).

%%%
%%% EXPORTS
%%%

write_new(CAPemPath, PriPemPath) ->
    PriKey = public_key:generate_key({namedCurve,secp521r1}),
    PubKey = PriKey#'ECPrivateKey'.publicKey,
    CertDer = ecc_root_cert(PubKey,PriKey),
    CAPem = pem_encode([{'Certificate',CertDer,not_encrypted}]),
    PriKeyPem = pem_encode([pem_entry_encode('ECPrivateKey', PriKey)]),
    ok = file:write_file(CAPemPath, CAPem),
    ok = file:write_file(PriPemPath, PriKeyPem),
    ok.

%% Open a CA certificate file to use later with forge/2.
load(CAPath, PriKeyPath) ->
    error(unimplemented).

%% Create a new cert for the given host name/ip number.
forge(Host, CACert) ->
    error(unimplemented).

%%%
%%% INTERNAL
%%%

attributes(L) ->
    {rdnSequence,
     [[#'AttributeTypeAndValue'{type=T,value=V}] || {T,V} <- L]}.

timefmt({Y,Mo,D},{H,Mi,S}) ->
    io_lib:format("~2..0B~2..0B~2..0B~2..0B~2..0B~2..0BZ", [Y rem 100,Mo,D,H,Mi,S]).

validity() ->
    {{Y,M,D},Time} = calendar:universal_time(),
    #'Validity'{
       notBefore = {utcTime,timefmt({Y,M,D},Time)},
       notAfter = {utcTime,timefmt({Y+1,M,D},Time)}
      }.

extensions(L) -> [#'Extension'{extnID=Oid, critical=Crit, extnValue=V}
                  || {Oid,Crit,V} <- L].

keyIdentifier(KeyBin) ->
    crypto:hash(sha, KeyBin).

randSerial() ->
    <<Serial:160/integer>> = crypto:strong_rand_bytes(20),
    Serial.

utf8Name(Bin) -> {rdnSequence, [{utf8String,Bin}]}.

ecc_root_cert(PubKey, PriKey) ->
    ContactInfo = attributes([
        {?'id-at-commonName', {utf8String,<<?ISSUER_CN>>}},
        {?'id-at-organizationName', {utf8String,<<?ISSUER_ORG>>}},
        %%{?'id-at-countryName', {printableString,<<"us">>}}
        %% should be the above? does not work.
        {?'id-at-countryName', "us"}
    ]),
    {ok,PubKeyParams} = 'OTP-PUB-KEY':encode('EcpkParameters',
                                             {namedCurve, ?'secp521r1'}),
    PubKeyInfo = #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{
            algorithm = ?'id-ecPublicKey',
            %%parameters = {namedCurve, ?'secp521r1'}
            parameters = {namedCurve, ?'secp521r1'}
        },
        % 4 means the OCTECT STREAM is uncompressed
        subjectPublicKey = #'ECPoint'{point=PubKey}
    },
    Extensions = extensions([
        {?'id-ce-subjectKeyIdentifier',false,keyIdentifier(PubKey)},
        {?'id-ce-basicConstraints',true,
         #'BasicConstraints'{cA=true, pathLenConstraint=asn1_NOVALUE}},
        {?'id-ce-keyUsage',false,
         [digitalSignature,keyEncipherment,dataEncipherment,keyCertSign,cRLSign]}
    ]),
    SignatureAlgorithm = #'SignatureAlgorithm'{
        algorithm = ?'ecdsa-with-SHA512',
        parameters = {namedCurve, ?'secp521r1'}
    },
    TBSCertificate = #'OTPTBSCertificate'{
        version = v3,
        serialNumber = randSerial(),
        signature = SignatureAlgorithm,
        issuer = ContactInfo,
        validity = validity(),
        subject = ContactInfo,
        subjectPublicKeyInfo = PubKeyInfo,
        issuerUniqueID = asn1_NOVALUE,
        subjectUniqueID = asn1_NOVALUE,
        extensions = Extensions
    },
    public_key:pkix_sign(TBSCertificate, PriKey).

