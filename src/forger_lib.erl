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
-define(PIROXY_ORG, "Pirate Proxy Dev Team").
-define(PIROXYCA_CN, "Pirate Proxy Root CA").
-define(PIROXYCA_ORG, ?PIROXY_ORG).
-define(PIROXYCA_CO, "us").
%% this is a little bit ridiculous...
-define(CERT_SERIAL(Cert), Cert#'Certificate'.tbsCertificate#'TBSCertificate'.serialNumber).
-define(CERT_PUBKEY(Cert), Cert#'Certificate'.tbsCertificate#'TBSCertificate'.subjectPublicKeyInfo#'SubjectPublicKeyInfo'.subjectPublicKey).

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
    Exts = ca_extensions(PubKey),
    CertDer = ecc_certificate(issuer(), PubKey, PriKey, Exts),
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
forge(FQDNs, {CACert,CAPriKey}) ->
    [Hd|_] = FQDNs,
    Contact = [{?'id-at-commonName', Hd}],
    PriKey = generate_key({namedCurve,secp521r1}),
    PubKey = PriKey#'ECPrivateKey'.publicKey,
    Exts = host_extensions(PubKey, FQDNs, CACert),
    CertDer = ecc_certificate(Contact, PubKey, CAPriKey, Exts),
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
                  #'AttributeTypeAndValue'{type=T,value={utf8String,V}};
              ({T,V}) ->
                  #'AttributeTypeAndValue'{type=T,value=V}
          end,
    sequence(map(Fun, L)).

sequence(L) ->
    {rdnSequence, [[X] || X <- L]}.

issuer() ->
    [{?'id-at-commonName',<<?PIROXYCA_CN>>},
     {?'id-at-organizationName',<<?PIROXYCA_ORG>>},
     {?'id-at-countryName',?PIROXYCA_CO} % use a string (list) NOT a binary
    ].  

%% all extensions are critical
extension_recs(L) ->
    map(fun ({Oid,Crit,V}) ->
                #'Extension'{extnID=Oid, critical=Crit, extnValue=V}
        end, L).

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
                    {?'id-ce-certificatePolicies',false,
                     [#'PolicyInformation'{policyIdentifier=?'anyPolicy',
                                           policyQualifiers=asn1_NOVALUE}]},
                    {?'id-ce-extKeyUsage',false,
                     [?'id-kp-serverAuth', ?'id-kp-clientAuth']},
                    {?'id-ce-subjectAltName',false,
                     [{'dNSName',N} || N <- DnsNames]}]).

ecc_certificate(Subject0, SubjectPubKey, CaPriKey, Extensions) ->
    Subject = attributes(Subject0), % checks arguments early
    PubKeyInfo = #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{
            algorithm = ?'id-ecPublicKey',
            parameters = {namedCurve, ?'secp521r1'}
        },
        subjectPublicKey = #'ECPoint'{point=SubjectPubKey}
    },
    SignatureAlgorithm = #'SignatureAlgorithm'{
        algorithm = ?'ecdsa-with-SHA512',
        %%parameters = {namedCurve, ?'secp521r1'}
        parameters = asn1_NOVALUE
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
        extensions = Extensions
    },
    pkix_sign(TBSCertificate, CaPriKey).
