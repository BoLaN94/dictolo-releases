# Dictolo — izdanja

Ovdje stoje instaleri i manifest za automatsko ažuriranje aplikacije
[Dictolo](https://dictolo.com) — diktat za Windows.

**Izvorni kod nije ovdje** i repozitorij ga ne sadrži. Javan je samo zato što GitHub
fajlove uz izdanje daje anonimno skinuti jedino iz javnog repozitorija.

- Preuzimanje: [dictolo.com](https://dictolo.com)
- Dokumentacija: [docs.dictolo.com](https://docs.dictolo.com)

## Dvije stvari koje se lako pokvare

**`download_url` u manifestu pokazuje na commit, ne na `main`.** Aplikacija provjerava
sha256 svakog skinutog fajla. `raw.githubusercontent.com/.../main/...` CDN kešira oko pet
minuta, pa korisnik koji ažurira odmah nakon objave dobije stare bajtove i provjera padne.
Zato se fajlovi prvo commituju, pa se manifest generiše s tim commitom u `--base-url` i
commituje zasebno.

**Prelazi u novi red se ne konvertuju** (`.gitattributes`, `* -text`). Bez toga git na
Windowsu jednom tekstualnom fajlu pretvori CRLF u LF, sažetak se razlikuje od onog u
manifestu i ažuriranje padne na tom fajlu.
