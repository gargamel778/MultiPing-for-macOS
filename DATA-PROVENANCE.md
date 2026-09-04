# Where the MAC vendor data comes from

The bundled `oui.txt` is built by `Tools/refresh-oui.sh` (in the MultiPing-iOS
repo) directly from the IEEE Registration Authority's five public registry
files, and nothing else:

| Registry | File | Prefix width |
|---|---|---|
| MA-L | `https://standards-oui.ieee.org/oui/oui.csv` | 24-bit |
| MA-M | `https://standards-oui.ieee.org/oui28/mam.csv` | 28-bit |
| MA-S | `https://standards-oui.ieee.org/oui36/oui36.csv` | 36-bit |
| IAB  | `https://standards-oui.ieee.org/iab/iab.csv` | 36-bit (retired registry) |
| CID  | `https://standards-oui.ieee.org/cid/cid.csv` | 24-bit |

It is **not** derived from Wireshark's `manuf`, nor from any other
redistribution. This is recorded because the distinction is checkable and worth
being able to demonstrate: `manuf` title-cases roughly 18% of registry names
(`ABB AB PGHV` becomes `Abb Ab Pghv`) and carries editorial text of Wireshark's
own authorship, such as calling `00:00:00` "Officially Xerox, but 0:0:0:0:0:0 is
more common". Neither appears here — line 1 of `oui.txt` is
`000000<TAB>XEROX CORPORATION`, and ALL-CAPS registry names survive verbatim.

## Why the registry files may be redistributed

The registry files themselves carry no copyright notice, no licence text and no
terms of use; they begin directly with the CSV header row.

IEEE's Registration Authority has stated:

> IEEE does not assert any copyright in the OUI Public Listing or attempt to
> restrict distribution of the listing in any way. The IEEE Registration
> Authority does, however, strongly encourage those who use the list to obtain
> it directly from IEEE (and to update it on a regular basis) to ensure the
> integrity of the information.

That statement was published on `standards.ieee.org/develop/regauth/general.html`,
a page IEEE has since retired. It is preserved verbatim, attributed to IEEE
(2014), in Debian's `ieee-data` package copyright file, which classifies these
same four files as Public Domain and has shipped them in Debian `main` since
2013:

> https://metadata.ftp-master.debian.org/changelogs/main/i/ieee-data/ieee-data_20220827.1_copyright

IEEE's encouragement is followed at the source: the bundled table is regenerated
directly from the five registries by `Tools/refresh-oui.sh`, never copied from a
redistribution. The iOS build additionally offers an in-app refresh that fetches
from IEEE directly; the macOS build ships the generated snapshot.

Independently of any licence, a registry of assigned numbers mapped to the
organisation each was assigned to is a collection of facts, and under
*Feist Publications v. Rural Telephone Service*, 499 U.S. 340 (1991), facts and
the effort of compiling them are not copyrightable in the United States.

## Attribution

Not required by anything above, but shown in-app anyway, as every comparable
tool does:

> Vendor data from the IEEE public registries (MA-L, MA-M, MA-S, IAB and CID).
