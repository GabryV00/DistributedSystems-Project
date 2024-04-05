- [x] Buildare l'applicazione in maniera consistente
- [x] Creazione processo per MST
  - [ ] Avvisare vicini se il pid cambia
- [x] Join senza triggerare veramente il calcolo del MST
- [x] Creazione connection handler (intanto processo che non fa nulla)
- [x] Calcolo MST
  - [x] Inizialmente senza sessione, ma fare in modo che il nodo sia in stato di
    search
  - [x] Aggiungere gestione delle sessioni del MST
  - [x] Gestire nodo che fa join mentre gli altri stanno gia' calcolando MST
  - [x] Ricavare gli output di GHS in modo che siano utilizzabili da nodo
- [x] Durante la fase di inizializzazione i nodi devono comunicarsi i propri pid
  per il calcolo del MST
- [x] Request to communicate
  - [x] Routing
  - [x] Widest path
- [ ] Comunicazione in entrambi i versi/al contrario
- [ ] Close connection avvisando destinatario
- [ ] Documentare bene


GUI
===

- [ ] Visualizzare MST su grafo
- [ ] Lista coi nodi nella webgui con pallino rosso o verde se il nodo sta
  calcolando il MST oppure ha finito
- [ ] Mostrare esito operazioni su grafo in base a valori di ritorno di erlang


Test/robe
=========

- [ ] Inizializzazione rete
- [ ] Join (aggiunta nodo)
- [ ] Request to communicate
- [ ] Close connection

- [ ] Calcolo MST
- [ ] Calcolo MST quando nodo muore
- [ ] Eliminazione nodo
- [ ] Invio/ricezione dati





Problemi da risolvere durante il calcolo MST
============================================

- [x] Nodo che muore definitivamente
- [x] Richiesta che va in timeout, ma nodo contattato non e' morto e risponde
  piu' tardi del previsto
- [x] **Problema attuale** con timeout vari si arriva al punto in cui alcuni
  nodi sono ancora in stato "computing", quindi non hanno ricevuto {done} dal
  processo del MST
  - [x] Quelli che sono ancora in "computing" *non* sono aggiornati all'ultima
  sessione del MST -> accade perché dal punto di vista degli altri nodi questi
  sono stati disconnessi dalla rete a causa di un timeout
