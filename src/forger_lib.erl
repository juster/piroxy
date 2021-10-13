%%% forger_lib
%%%
%%% Forges certificates from other hosts so that we can place a
%%% man-in-the-middle to eavesdrop on TLS streams. This requires
%%% that we also create our own self-signed certificate.
%%%
%%% Author: Justin Davis <jrcd83@gmail.com>
%%%

-module(forger_lib).
-include_lib("public_key/include/public_key.hrl").
-import(public_key, [pem_entry_encode/3, pem_encode/1]).
-define(PIROXY_ORG, "Piroxy Developers").
-define(PIROXYCA_CN, "Piroxy Root CA").
-define(PIROXYCA_ORG, ?PIROXY_ORG).
-define(PIROXYCA_CO, "US").
%% this is a little bit ridiculous...
-define(CERT_SERIAL(Cert), Cert#'Certificate'.tbsCertificate#'TBSCertificate'.serialNumber).
-define(CERT_PUBKEY(Cert), Cert#'Certificate'.tbsCertificate#'TBSCertificate'.subjectPublicKeyInfo#'SubjectPublicKeyInfo'.subjectPublicKey).
-define(EC_CURVE, ?'secp521r1').

%% References:
%% RFC5280: has the relevant ASN1 information
%% RFC5480: info specific to using elliptic curve with PKI, for example:
%% RFC7748: describes djb's X25519 curve
%% (I had been useing secp521r1 but it was banned...?)

-export([generate_ca_pair/1, forge/2]).

%%%
%%% EXPORTS
%%%

extract_pubkey(#'ECPrivateKey'{publicKey=PubKey}) ->
    PubKey;

extract_pubkey(#'RSAPrivateKey'{modulus=M,publicExponent=E}) ->
    #'RSAPublicKey'{modulus=M,publicExponent=E}.

%% Returns two PEM-encoded binaries: a Certificate entry and ECPrivateKey entry.
%% The ECPrivateKey entry is encrypted with the provided Passwd.
generate_ca_pair(Passwd) ->
    KeyPair = public_key:generate_key({rsa,2048,65537}),
    %%KeyPair = public_key:generate_key({namedCurve,?EC_CURVE}),
    Exts = ca_extensions(extract_pubkey(KeyPair)),
    CertDer = certificate(issuer(), KeyPair, KeyPair, Exts),
    EncOpts = {{"DES-CBC",crypto:strong_rand_bytes(8)}, Passwd},
    EntType = element(1,KeyPair),
    PriKeyEnt = pem_entry_encode(EntType,KeyPair,EncOpts),
    CertPem = pem_encode([{'Certificate',CertDer,not_encrypted}]),
    KeyPem = pem_encode([PriKeyEnt]),
    {CertPem, KeyPem}.

%% Create a new cert/private key for the given host name/ip number.
%% FQDNs = [binary()]
forge(FQDNs, {CACert,CAKeyPair}) ->
    [Hd|_] = FQDNs,
    Contact = [{?'id-at-commonName', Hd}],
    KeyPair = public_key:generate_key({rsa,2048,65537}),
    %%KeyPair = public_key:generate_key({namedCurve,?EC_CURVE}),
    Exts = host_extensions(KeyPair, FQDNs, CACert),
    CertDer = certificate(Contact, KeyPair, CAKeyPair, Exts),
    {CertDer,KeyPair}.

%%%
%%% INTERNAL
%%%

timefmt({Y,Mo,D},{H,Mi,S}) ->
    io_lib:format("~2..0B~2..0B~2..0B~2..0B~2..0B~2..0BZ",
                  [Y rem 100,Mo,D,H,Mi,S]).

validity() ->
    {{Y,M,D},Time} = calendar:universal_time(),
    #'Validity'{
       notBefore = {utcTime,timefmt({Y,M,D},Time)},
       notAfter = {utcTime,timefmt({Y+1,M,D},Time)}
      }.

keyIdentifier(KeyBin) when is_binary(KeyBin) ->
    crypto:hash(sha, KeyBin);

keyIdentifier(Key) when is_tuple(Key) ->
    keyIdentifier(public_key:der_encode(element(1,Key),Key)).

randSerial() ->
    N = 18,
    <<Serial:(8*N)/integer>> = crypto:strong_rand_bytes(N),
    Serial.

attributes(L) ->
    Fun = fun ({T,V}) when is_binary(V) ->
                  #'AttributeTypeAndValue'{type=T,value={utf8String,V}};
              ({T,V}) ->
                  #'AttributeTypeAndValue'{type=T,value=V}
          end,
    %% don't forget each attribute is wrapped in a list for some reason
    {rdnSequence, [[X] || X <- lists:map(Fun, L)]}.

issuer() ->
    [{?'id-at-commonName',<<?PIROXYCA_CN>>},
     {?'id-at-countryName',?PIROXYCA_CO}, % use a string (list) NOT a binary
     {?'id-at-organizationName',<<?PIROXYCA_ORG>>}
    ].

%% all extensions are critical
extension_recs(L) ->
    [#'Extension'{extnID=Oid, critical=Crit, extnValue=V} || {Oid,Crit,V} <- L].

ca_extensions(SubjectPubKey) ->
    extension_recs([{?'id-ce-subjectKeyIdentifier',false,
                     keyIdentifier(SubjectPubKey)},
                    {?'id-ce-basicConstraints',true,
                     #'BasicConstraints'{cA=true, pathLenConstraint=asn1_NOVALUE}},
                    {?'id-ce-keyUsage',true,
                     [digitalSignature,keyCertSign,cRLSign]},
                    {?'id-ce-certificatePolicies',false,
                     [#'PolicyInformation'{policyIdentifier=?'anyPolicy',
                                           policyQualifiers=asn1_NOVALUE}]}
                   ]).

host_extensions(SubjectPubKey, DnsNames, CACert) ->
    extension_recs([{?'id-ce-subjectKeyIdentifier',false,
                     keyIdentifier(SubjectPubKey)},
                    {?'id-ce-authorityKeyIdentifier',false,
                     #'AuthorityKeyIdentifier'{
                        keyIdentifier=keyIdentifier(?CERT_PUBKEY(CACert))
                        %%authorityCertIssuer={utf8String,<<?ISSUER_CN>>},
                        %%authorityCertSerialNumber=?CERT_SERIAL(CACert)
                       }},
                    {?'id-ce-basicConstraints',true,
                     #'BasicConstraints'{cA=false, pathLenConstraint=asn1_NOVALUE}},
                    {?'id-ce-keyUsage',true,
                     [digitalSignature,keyEncipherment,keyAgreement]},
                    %%{?'id-ce-certificatePolicies',false,
                    %% [#'PolicyInformation'{policyIdentifier=?'anyPolicy',
                    %%                       policyQualifiers=asn1_NOVALUE}]},
                    {?'id-ce-extKeyUsage',false,
                     [?'id-kp-serverAuth', ?'id-kp-clientAuth']},
                    {?'id-ce-subjectAltName',false,
                     [{'dNSName',N} || N <- DnsNames]}]).

public_key_info(#'RSAPrivateKey'{} = K) ->
    #'OTPSubjectPublicKeyInfo'{
       algorithm = #'PublicKeyAlgorithm'{
                      algorithm = ?'rsaEncryption',
                      parameters = 'NULL'
                     },
       subjectPublicKey = extract_pubkey(K)};

public_key_info(#'ECPrivateKey'{} = K) ->
    #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{
            algorithm = ?'id-ecPublicKey',
            parameters = {namedCurve, ?EC_CURVE}
        },
        subjectPublicKey = #'ECPoint'{point=extract_pubkey(K)}}.

signature_algorithm(#'ECPrivateKey'{}) ->
    #'SignatureAlgorithm'{
       algorithm = ?'ecdsa-with-SHA512'
      };

signature_algorithm(#'RSAPrivateKey'{}) ->
    #'SignatureAlgorithm'{
       algorithm = ?'sha512WithRSAEncryption',
       parameters = 'NULL'
      }.

certificate(Subject, SubjectKeyPair, CAKeyPair, Extensions) ->
    TBSCertificate = #'OTPTBSCertificate'{
        version = v3,
        serialNumber = randSerial(),
        signature = signature_algorithm(CAKeyPair),
        issuer = attributes(issuer()),
        validity = validity(),
        subject = attributes(Subject), % checks arguments early,
        subjectPublicKeyInfo = public_key_info(SubjectKeyPair),
        issuerUniqueID = asn1_NOVALUE,
        subjectUniqueID = asn1_NOVALUE,
        extensions = Extensions
    },
    public_key:pkix_sign(TBSCertificate, CAKeyPair).
