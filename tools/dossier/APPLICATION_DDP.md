# Digital Defenders Partnership — draft answers

Up to 10,000 EUR over four to six months. Dutch, and their pages invite
providers of secure software directly, which is why this is the second
application rather than a fallback.

The scope is deliberately narrow and disjoint from the NLnet proposal: this
asks for the device-hardening work, which NLnet's milestones do not contain.
Nothing here appears in that budget, and the NLnet form will name this
application in its other-funding field.

Fill the amount before sending; everything else is written.

---

## What is the project

LiveResilient is an open-source calling and messaging kit for links that carry
packets but not a conversation — a few kilobits per second, heavy loss, seconds
of latency. It exists because a network that is throttled rather than cut
leaves people with a connection icon and no way to send a voice message.

The engineering is done and public: six features between 29 and 5,926 bytes on
the wire, a 24-cell impairment matrix, measurements recorded on a physical
device, continuous integration green on public infrastructure, Apache-2.0 for
the client and AGPL-3.0 for the server.

Repository: https://github.com/tlscodes/liveresilient

## What is this request for

Not features. The three things that decide whether a person can be identified
by the tool they are carrying.

```
private keys in the platform keystore   they are in a plain file today
delete-everything                        no such action exists today
a pilot on devices we do not own         every measurement is from one iPhone
```

The first two are quoted from the project's own code, not inferred:
`packages/security/lib/src/key_store.dart` says of its shipped implementation
"There is no encryption, no OS keychain integration", and a search for a wipe
action across the application returns nothing.

For most people in the situation this tool targets, the danger is not someone
reading the wire. It is a phone in someone else's hands at a checkpoint. A tool
that protects a conversation from the network and not from a search gives a
false sense of protection, which is worse than no tool — and there is a recent
precedent for exactly that outcome with a tool distributed at scale during a
shutdown.

## What the money buys

```
platform keystore and keychain storage for private keys
at-rest protection for local data, or storing nothing at all
a delete-everything action covering keys, history, contacts and logs
four loaner handsets for pilot participants, receipted and returned
the pilot itself: onboarding, supervised sessions, and merging results
```

The handsets are the only hardware line, and they exist because the pilot's
acceptance test requires measurements on devices that are not the developer's,
from volunteers who cannot be asked to own a particular model.

## How it will be verified

Each item has a mechanical test, which is how the rest of this repository
works: a command that exits zero, and nothing reported complete without it.

```
keystore     a test asserting a release build cannot select the dev key store
wipe         a test that writes, wipes, restarts and finds nothing
pilot        six end-to-end rows produced on testers' devices, in the same
             results file and the same format as the developer's own
```

## Who it is for, and how we will not get that wrong

There are no users today and this application does not claim any. The pilot
recruits through an organisation with a duty-of-care process rather than
directly, because a developer in the Netherlands cannot obtain informed consent
from someone whose risk they cannot assess. The first cohort is deliberately
people who are not at risk.

The project publishes its own gaps before a reviewer finds them: `SECURITY.md`
states what is unencrypted, what the server can see, and what nobody has
audited. That is the same reason this application is for hardening rather than
for features.

## Amount and duration

```
[owner] amount, up to 10,000 EUR
[owner] duration, four to six months
```

## Other funding

None received. An application to NLnet's open call was submitted on
3 September 2026 for a disjoint set of deliverables — transport encryption, the
transport core from source, an Android arm and a security review — none of
which appear in this request.

---

## Every number in this draft, and where it comes from

For the applicant, not for the form. Check each before sending; a figure that
cannot be traced is cut rather than softened.

```
29 to 5,926 bytes, six features    tools/phase5/h3_results.tsv
24-cell impairment matrix          tools/t2/h2_results.tsv via report_matrix.py
measured on a physical device      tools/dossier/e2e_ios_results.tsv
  - over the test harness lane     tools/dossier/LANE_TABLE.md
"no OS keychain integration"       packages/security/lib/src/key_store.dart
no wipe action                     grep across apps/reference_app/lib
four handsets, about 300 EUR each  NLnet application, milestone 4, same basis
10,000 EUR ceiling, 4-6 months     grants.digitaldefenders.org
NLnet submitted 3 September 2026   put the real date in before sending
```

No probability of acceptance appears anywhere in this application, because none
is published by anyone.
