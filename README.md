# My Safe — guida a compilazione e installazione

App iOS nativa (SwiftUI, iOS 17+, ottimizzata per iPhone 15) per archiviare, per ogni organizzazione, solo: **Organization, User, Password**.

> I file non sono stati compilati in questo ambiente (nessun Xcode disponibile). Alla prima compilazione potrebbero servire piccoli ritocchi: prova su un iPhone reale prima di affidarci credenziali importanti.

## 1. Requisiti
- Mac con Xcode 16 o successivo (consigliato Xcode 26)
- iPhone 15 con iOS 17 o successivo, collegato con cavo
- Apple ID. **Per iCloud/CloudKit serve l'Apple Developer Program (a pagamento).** Con l'account gratuito l'app funziona solo in locale (vedi punto 7).

## 2. Creare il progetto
1. Xcode ▸ File ▸ New ▸ Project ▸ **iOS ▸ App**
2. Product Name: `MySafe` · Interface: **SwiftUI** · Language: **Swift** · Storage: None · Testing: nessuno
3. Organization Identifier: ad es. `com.tuonome` (il Bundle ID sarà `com.tuonome.MySafe`)
4. Elimina i file generati `ContentView.swift` e `MySafeApp.swift` (Move to Trash)
5. Trascina nel progetto tutti i file `.swift` di questa cartella (spunta *Copy items if needed* e il target MySafe)

## 3. Impostazioni di build
Target MySafe ▸ **Build Settings**:
- *iOS Deployment Target*: **17.0**
- *Default Actor Isolation* (Xcode 26): **nonisolated**
- *Swift Language Mode*: **Swift 5**

## 4. Signing & Capabilities
- *Signing*: scegli il tuo Team
- **+ Capability ▸ iCloud** ▸ spunta **CloudKit** ▸ aggiungi un container (es. `iCloud.com.tuonome.MySafe`, cioè `iCloud.` + Bundle ID: il codice usa il container predefinito)
- **+ Capability ▸ Background Modes** ▸ spunta **Remote notifications** (permette a CloudKit di avvisare l'app delle modifiche)

## 5. Info e lingua (l'app è in inglese)
- Target ▸ **Info** ▸ aggiungi la chiave *Privacy – Face ID Usage Description* con testo: `My Safe uses Face ID to protect access to your credentials.`
- Lascia **English** come lingua di sviluppo (predefinita): così anche i messaggi di sistema (Face ID, pulsanti) sono in inglese.

## 6. Installare sull'iPhone
1. iPhone: Impostazioni ▸ Privacy e sicurezza ▸ **Modalità sviluppatore** ▸ attiva e riavvia
2. Collega l'iPhone, sblocca e tocca "Autorizza"
3. In Xcode scegli il tuo iPhone come destinazione e premi **⌘R**
4. Alla prima apertura: Impostazioni ▸ Generali ▸ VPN e gestione dispositivi ▸ autorizza il tuo profilo sviluppatore
5. Sull'iPhone devono essere attivi: codice di sblocco, Face ID, iCloud (con Portachiavi iCloud attivo)

Le app installate con l'account gratuito scadono dopo 7 giorni; con l'account a pagamento dopo 1 anno (oppure usa TestFlight).

## 7. Senza account a pagamento (solo locale)
In `VaultStore.swift` imposta `static let cloudEnabled = false` e non aggiungere la capability iCloud.

## 8. CloudKit: schema di produzione
Le build lanciate da Xcode usano l'ambiente *Development*: i tipi di record (`Credential`, `KeyWrap`) si creano da soli al primo salvataggio. Prima di TestFlight/App Store apri la **CloudKit Console** ▸ il tuo container ▸ **Deploy Schema Changes to Production**.

## 9. Primo avvio
1. "Crea nuovo archivio" → compare la **chiave di recupero** (52 caratteri). Conservala stampata o in un luogo sicuro: non viene salvata né mostrata di nuovo.
2. Face ID sblocca l'app; da Impostazioni scegli il blocco automatico.
3. Nuovo iPhone: se il Portachiavi iCloud è attivo la chiave arriva da sola e basta Face ID; altrimenti usa "Ripristina con chiave di recupero".

## Come funziona la sicurezza
- **Cifratura**: ogni registrazione è cifrata con AES-256-GCM (CryptoKit), nonce casuale, id registrazione come dati autenticati.
- **Chiave dati**: 256 bit casuali nel Keychain Apple (sincronizzabile via Portachiavi iCloud, accessibile solo a dispositivo sbloccato). Resta in memoria solo mentre l'app è sbloccata.
- **Chiave di recupero**: 256 bit casuali, mostrata una sola volta. In CloudKit c'è solo la chiave dati cifrata con una chiave derivata (HKDF-SHA256) da quella di recupero.
- **CloudKit**: database privato dell'utente; contiene solo blob cifrati, data di modifica e il key wrap. Nessun testo in chiaro.
- **Log**: il codice non stampa mai dati; nessuna password finisce in log o nel cloud.
- **Blocco**: Face ID (o codice del dispositivo); blocco automatico in background con tempo scelto; copertura dello schermo nello switcher; password nascosta di default.
- **Appunti**: copia solo locale (niente Appunti Universali), cancellazione automatica dopo 30 secondi.
- **Nessun dato demo**: l'archivio parte vuoto.

## Limiti da conoscere
- Poiché la chiave si sincronizza via Portachiavi iCloud, Face ID è un controllo dell'app e non protegge la chiave a livello di Keychain. Per una chiave solo locale protetta da biometria si può usare un elemento Keychain non sincronizzato con `SecAccessControl`, a costo di dover usare la chiave di recupero sugli altri dispositivi.
- Il blocco automatico si basa sul tempo trascorso in background (non su inattività con l'app in primo piano).
- Gli screenshot non sono bloccabili da iOS; il contenuto è però coperto nello switcher.
- Oltre ai tre campi, ogni registrazione ha un identificativo casuale e una data di modifica, necessari alla sincronizzazione (non contengono dati utente).
