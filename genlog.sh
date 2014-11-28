#!/bin/bash
#
#	Genlog is a script used for generating several kinds of logfiles and
#       automatic upload them on pastebin.
#
#	Copyright (C) 2014 sten_gun, syscall, v0k3.
#
#	Genlog is free software: you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation, either version 3 of the License, or
#	(at your option) any later version.
#
#	Genlog is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	You should have received a copy of the GNU General Public License
#	along with genlog.  If not, see <http://www.gnu.org/licenses/>.
#

umask 0011

# Rimpiazza echo ed echo -n, impedendo echo -e e le possibili combinazioni
# Sintassi accettata:
#  echo -n "testo"  # stampa senza a capo finale
#  echo "testo"     # stampa con a capo finale
#  echo             # stampa una riga vuota
function echo {
  if [ $# -gt 1 ] && [ "$1" = "-n" ]; then
    shift
    printf %s "$*"
  else
    printf %s\\n "$*"
  fi
}

#--------------------------------------------------------------------------
# Costanti
#--------------------------------------------------------------------------
PATH="/bin:/sbin:/usr/bin:/usr/sbin"

# nome utente
utente=$(logname) &&
[ "$utente" != "root" ] || {
  utente=
  tmputente=
  for tmputente in $(users); do
    if [ "$tmputente" = "root" ]; then
      continue
    elif [ -z "$utente" ]; then
      utente=$tmputente
    elif [ "$utente" != "$tmputente" ]; then
      utente=
      break
    fi
  done
  if [ -z "$utente" ]; then
    # NOTA: "root" è permesso (solo) se scelto esplicitamente dall'utente
    echo -n "Inserisci il tuo nome utente: "
    read tmputente &&
    # non può contenere: spazi, tabulazioni, nuove righe; né essere vuota
    [ -n "${tmputente##*[[:space:]]*}" ] &&
    # l'utente deve aver effettuato il login (anche in altre console)
    case " $(users) " in
      *" ${tmputente} "* ) true
                           ;;
      * ) false
          ;;
    esac || {
      echo "Nome utente invalido o non ha effettuato il login!" >&2
      exit 255
    }
    utente=$tmputente
  fi
  unset tmputente
}
readonly utente
readonly nomehost=$(hostname)
readonly log="/tmp/Inforge_GNULinux-$(date +%d%b_%H%M%S).log"

readonly ROSSO="\033[01;31m"
readonly VERDE="\033[01;32m"
readonly BLU="\033[01;34m"
readonly GIALLO="\033[00;33m"
readonly BOLD="\033[01m"
readonly FINE="\033[0m"

function canclinea {
    tput sc
    tput el
    tput rc
}

function _intro {
  clear  
  printf %b "$BLU
		(_)_ __  / _| ___  _ __ __ _  ___   _ __   ___| |_ 
		| | '_ \| |_ / _ \| '__/ _' |/ _ \ | '_ \ / _ \ __|	    
		| | | | |  _| (_) | | | (_| |  __/_| | | |  __/ |_      
		|_|_| |_|_|  \___/|_|  \__, |\___(_)_| |_|\___|\__|		   	
				       |___/                 	   
						genlog v0 $FINE 
			    $VERDE[Per gli utenti della sez. GNU/Linux]$FINE
	   
	            $BOLD Compatibile con Gentoo, Arch Linux, Debian e derivate.$FINE		   
------------------------------------------------------------------------------------------
"
}

function _avvertenze {
	local rispondi
	printf %b "$BOLD$ROSSO
             AVVERTENZE:$FINE genlog genererà un file di log che sarà inviato$BLU
           AUTOMATICAMENTE$FINE al sito paste2.org fornendoti un link da inserire	
                 successivamente sulla tua discussione in inforge.net

Per l'esecuzione di questo script è consigliabile soddisfare le seguenti dipendenze:
"
## Removed the 'must-have' dependencies
#
#  _pack "wget" "nolog"
#  _pack "pastebinit" "nolog"
#  if [ $ID == "gentoo" ]; then
#     _pack "pciutils" "nolog"
#     _pack "usbutils" "nolog"
#  fi

  _pack "xclip" "nolog" # for automatic copying in the clipboar
  xclip_installed=$?
  _bold "Continuare l'esecuzione [S/n]? "
  read rispondi
  case $rispondi in
    ""|[Ss]) return  ;;
    *)	 _exit
  esac
}

# Funzione che esegue un check preliminare
function _check {
  if [ $EUID -ne 0 ]; then # Lo script viene lanciato da root?
    echo "Lo script deve essere lanciato da root" && _exit
  fi
 
  # Se esiste già un file di log con lo stesso nome oppure file compressi con lo
  # stesso nome di quelli che verranno creati, lo script chiede se cancellarli o meno
  local risp
  if [ -f "$log" ]; then
    echo $'\n'"Esiste già un file ${log} nella directory corrente."
    echo -n "Sovrascivere [S/n]? "
    read risp
    case "$risp" in
      ""|[Ss]) rm -f -- "$log" ;;
      *)       _exit
    esac
  fi
}

# Rileva la distribuzione corrente tramite /etc/os-release e imposta la
# funzione per il package manager e alcune variabili di sistema, se necessario.
function _osprobe {
	ID=$(sed -n 's/^ID=//p' /etc/os-release)
	VERSION_ID=$(sed -n 's/^VERSION_ID=//p' /etc/os-release)
	case $ID in
	  arch)
	    _packageman=_pacman
	    INIT="systemd"
	    ;;
	  debian)
	    _packageman=_apt
	    if [ $VERSION_ID -gt 7 ]; then
	      INIT="systemd"
	    else
	      INIT="init.d"  
              readonly STABLE="wheezy"
              readonly TESTING="jessie"
	    fi
	    ;;
	  gentoo)
	    _packageman=_portage
	    $_packageman "ricercalocale" "systemd" 2&>1 /dev/null
	      if [ $? -eq 0 ]; then
	        INIT="systemd"
	      else
		INIT="init.d"
	      fi
	    ;;
	  *)
	    echo "Sistema non supportato, se vuoi estendere il supporto alla tua distro forka il progetto su gitorious e poi manda il pull del commit al master branch!"
	    _exit
	esac
}

function _invia {
  local paste_url='http://paste2.org' 
  local pastelink
  echo
  _prompt "Caricamento del log in corso ...."
  #pastelink="$(pastebinit -a '' -b $paste_url -i $log 2>/dev/null)"
  _ok
  tput cuu 1  # in alto di una riga
  tput cuf 39  # a destra di 39
  printf %b "$VERDE$BOLD Fatto!$BLU link ->$FINE " $pastelink
  if [ $xclip_installed -eq 1 ]; then
    echo "$pastelink" | xclip -selection clipboard
    printf %b "$VERDE$BOLD \n Xclip$FINE installato!!$BLU$BOLD Link automaticamente copiato negli appunti!$FINE"
  fi
  echo
  printf %b "$ROSSO$BOLD \n RICORDA:$FINE Non dimenticare di postare il link nel tuo thread dedicato su inforge!$FINE"
}

function _upload {
  local rispondi
  if [ ! -f /usr/bin/pastebinit ]; then
    printf %b "$ROSSO\n ATTENZIONE:$FINE Non è possibile inviare il log!\n Il pacchetto $BOLD'pastebinit'$FINE non è installato."
    return 1
  fi
      _invia
}

# --------------------------------------------------------------------------
# Funzione di stampa menù e selezione del problema
# --------------------------------------------------------------------------

function _scelta {
  local num
  _intro
  _bold "
Selezionare il tipo di problema per il quale verrà generato il file di log"
  echo "\
[1] Problemi relativi alle connessioni di rete
[2] Problemi video
[3] Problemi audio
[4] Problemi di gestione dei pacchetti
[5] Problemi di mount/unmount
[6] Problemi di funzionamento del touchpad
[7] Problemi con virtualbox
[8] Altro tipo di problema
[0] Uscita"
 
  while true; do
    _bold "Scegliere il numero corrispondente: "
    read num
    case "$num" in
        [1-8])	_wait   ;;& # ;;& -> va alla successiva occorrenza del carattere immesso
            1)	echo $'### Problemi di rete ###\n'            > "$log" && _rete   ;;&
            2)	echo $'### Problemi video ###\n'              > "$log" && _video  ;;&
            3)	echo $'### Problemi audio ###\n'              > "$log" && _audio  ;;&
            4)	echo $'### Problemi package manager ###\n'    > "$log" && $_packageman "check"    ;;&
            5)	echo $'### Problemi mount-unmount ###\n'      > "$log" && _mount  ;;&
            6)	echo $'### Problemi touchpad ###\n'           > "$log" && _tpad   ;;&
            7)  echo $'### Problemi virtualbox ###\n'	      > "$log" && _vbox   ;;&
            8)	echo $'### Solo informazioni generiche ###\n' > "$log" && _common ;;&
        [1-8])	break   ;; # Termina il ciclo 'while'
            0)	_exit   ;; # È stato inserito '0' . Uscita dallo script
            *)	# Tutti gli altri caratteri. Cancella l'input immesso e ripete la domanda
		tput cuu1 # in alto di una riga
		tput ed # cancella fino alla fine dello schermo
    esac
  done
}

# Funzione che stampa un pallino di colore verde in caso di comando con output
# Visualizza a video l'eventuale stringa passata come primo parametro ($1).
function _ok {
  echo
  tput cuu1  # in alto di una riga
  tput cuf1  # a destra di uno spazio
  # se non ci sono parametri, viene stampato solo il pallino
  if [ $# -eq 0 ]; then
    printf %b "${VERDE}•${FINE}\n" # stampa pallino e va a capo
  # se c'è un parametro, viene stampato il pallino e il parametro
  elif [ $# -eq 1 ]; then
    printf %b "${VERDE}•${FINE}"
    tput cuf 3 # a destra di tre spazi
    tput el    # cancella fino a fine riga
    printf %b "$1\n" # stampa il parametro e va a capo
  fi
}

# Funzione che stampa una pallino rosso in caso di comando privo di output
function _error {
  echo
  tput cuu1  # in alto di una riga
  tput cuf1 # a destra di uno spazio
  # se non ci sono parametri, viene stampato solo il pallino
  if [ $# -eq 0 ]; then
    printf %b "${ROSSO}•${FINE}\n" # stampa pallino e va a capo
  # se c'è un parametro, viene stampato il pallino e il parametro
  elif [ $# -eq 1 ]; then
    printf %b "${ROSSO}•${FINE}"
    tput cuf 3 # a destra di tre spazi
    tput el    # cancella fino a fine riga
    printf %b "$1\n" # stampa il parametro e va a capo
  fi
}

# Funzione che stampa in grassetto gli argomenti
function _bold {
  printf %b "$BOLD"
  echo -n "$*"
  printf %b\\n "$FINE"
}

# Funzione che invia nel file di log due righe tra le quali viene visualizzato il
# nome del comando (passato come primo parametro della funzione -> $1)
function nome_e_riga {
  echo "
******************************************
$1
******************************************" >> "$log"
}

# Funzione che stampa un messaggio di attesa e aspetta 2 secondi
function _wait {
  echo $'\nCreazione del log in corso...\n'
}

# Funzione che pulisce il file di log se presente e stampa un goodboy
function _exit {
  if [ -f "$log" ]; then
    rm -rf $log
  fi
  
  echo $'Script terminato\n'
  exit 0
}

# --------------------------------------------------------------------------
# Funzioni relative a ciascun problema selezionato
# --------------------------------------------------------------------------

# Informazioni comuni a tutti i tipi di problema
function _common {
  if [ $ID != "gentoo" ]; then
    local _lspci="/usr/bin/lspci"
    local _groups="/usr/bin/groups"
  else
    local _lspci="/usr/sbin/lspci"
    local _groups="/bin/groups"
  fi
  
  _data
  _dmi_decode
  _comando "/bin/uname -a"
  _file "/etc/os-release"
  _de_wm
  _file "/etc/X11/default-display-manager"
  _comando "$_groups" "su"
  _file "/var/log/syslog"
  _comando "/bin/dmesg -l err"
  _comando "/bin/dmesg -l warn"
  _comando "/bin/lsmod"
  _comando "$_lspci -knn"
  _comando "/usr/bin/lsusb"
  _comando "/sbin/fdisk -l"
  _file "/etc/fstab"
  _comando "/bin/findmnt"
  _comando "/bin/df"
  _firmware
  _pack "linux-headers"
  _pack "linux-image"
}

# Funzione relativa ai problemi di rete
function _rete {
  _common
  _file "/etc/network/interfaces"
  _file "/etc/hosts"
  _comando "/sbin/ifconfig"
  _comando "/sbin/ifconfig -a"
  _comando "/usr/sbin/rfkill list all"
  _comando "/bin/ping -c3 8.8.8.8" #DNS di Google 8.8.8.8
  _comando "/bin/ip addr"
  _comando "/bin/ip route list"
  _comando "/sbin/iwconfig"
  _comando "/sbin/iwlist scan"
  _comando "/sbin/route -n"
  _pack "resolvconf"
  _file "/etc/resolv.conf"
  _pack "DHCP"
  _file "/etc/dhclient.conf"
  _file "/etc/NetworkManager/NetworkManager.conf"
  _comando "/usr/bin/nmcli dev list"
  _comando "/usr/bin/nmcli device show"
  _demone "/usr/sbin/NetworkManager" "Network Manager"
  _demone "/usr/sbin/wicd" "Wicd"
}

# Funzione relativa a problemi video
function _video {
  _common
  _file "/etc/X11/xorg.conf"
  _dir "/etc/X11/xorg.conf.d/"
  _file "/var/log/Xorg.0.log"
  _comando "/usr/sbin/dkms status"
  _pack "xorg"
  _pack "nouveau"
  _pack "nvidia"
  _pack "mesa"
  _pack "fglrx"
}

# Funzione relativa ai problemi audio. Scarica ed esegue lo script ALSA
function _audio {
  _common
  _pack "alsa"
  
  local risp alsaurl="http://www.alsa-project.org/alsa-info.sh"
  
  echo $'\nI log relativi ai problemi audio sono ricavati attraverso lo script di debug'
  echo "ALSA prelevabile all'indirizzo: ${alsaurl}"
  _bold $'\nVerrà ora scaricato e eseguito lo script ALSA. Continuare [S/n]? '
  read risp
  case "$risp" in
    ""|[Ss])
	  # wget esiste?
	  if [ ! -f /usr/bin/wget ]; then
	    echo "Impossibile scaricare lo script ALSA. Installare il pacchetto wget."
	    return
	  fi
	  # Crea un file temporaneo in /tmp che conterrà lo script ALSA
    	  local tempfile=$(mktemp)
    	  # Scarica lo script ALSA
          _prompt "Download script ALSA"
	  wget -q -O "$tempfile" "$alsaurl"
	  # Se il download riesce...
	  if [ $? -eq 0 ]; then
	      _ok "Download script ALSA riuscito"
	      # Imposta i permessi dello script scaricato
	      chmod 777 "$tempfile"
	      nome_e_riga "Problemi audio"
	      # Esegue lo script ALSA
              _prompt "Esecuzione script ALSA"
	      su  -c "$tempfile --stdout >> $log" "$utente" && _ok || _error
	  else
	      _error "Download script ALSA fallito"
	  fi
	  
	  # Rimuove il file temporaneo
	  rm -- "$tempfile"
	  ;;
    *)
	  echo "Lo script ALSA non è stato ancora eseguito."
	  echo "Avviare manualmente lo script prelevabile a questo indirizzo:"
	  _bold "$alsaurl"
	  echo "Lo script ALSA va eseguito con i permessi di normale utente."
  esac
}

# Funzione relativa alla gestione dei pacchetti attraverso il sistema APT
function _apt {
  local _dpkg=/usr/bin/dpkg
  local _aptget=/usr/bin/apt-get
  local _aptcache=/usr/bin/apt-cache
  local _aptconfig=/usr/bin/apt-config
  case $1 in
    extpack)
	  # Variabile che contiene la release attualmente utilizzata
	  # Vengono tolti da sources.list eventuali spazi iniziali e tolte le righe che *non* iniziano con le stringhe
	  # "deb http://ftp.XX.debian.org" o con
	  # "deb ftp://ftp.XX.debian.org" o con
	  # "deb http://ftp2.XX.debian.org" o con
	  # "deb ftp://ftp2.XX.debian.org" e che *non* contengono un nome di release.
	  # Con "cut" viene prelevato il terzo campo (la release voluta)
	  local release=$(sed -r -e 's/^ *//' -e '/^deb (http|ftp):\/\/(ftp|ftp2)\...\.debian\.org.*('"$STABLE"' |stable |'"$TESTING"' |testing |sid |unstable )/!d' /etc/apt/sources.list | cut -d ' ' -f3)

	  local var="Pacchetti esterni"
	  _prompt "$var"

	  # Lo script DEVE rilevare almeno una release. Se la variabile "release" è nulla, c'è un errore nei repository
	  # oppure lo script deve essere modificato. Questa situazione accade per indirizzi di repository
	  # non previsti (vedere il modo in cui viene ricavata la variabile "release" in alto)
	  if [ -z "$release" ]; then
		nome_e_riga "${var} all'archivio \"NON RILEVATO!\""
		echo "Release non rilevata. Repository errati oppure è necessaria una modifica dello script" >> "$log" && _error
		return 1
	  fi

	  # Numero di release trovate
	  local num=$(echo "$release" | wc -l)

	  # Se il numero di release è diverso da 1, la funzione termina
	  if [ "$num" -ne 1 ]; then
		nome_e_riga "$var"
		echo "Sono presenti ${num} release in sources.list" >> "$log" && _error
		return
	  fi

	  local pkg=""

	  # Se il numero di release è uguale a 1, la variabile pkg conterrà i pacchetti *non* facenti parte della release
	  case "$release" in
			"$STABLE"|stable)
				 release="stable"
				 pkg=$(aptitude -F '%p %v %t' search '~i !~Astable'   --disable-columns | column -t) ;;
			"$TESTING"|testing)
				 release="testing"
				 pkg=$(aptitude -F '%p %v %t' search '~i !~Atesting'  --disable-columns | column -t) ;;
			sid|unstable)	
				 release="unstable"
				 pkg=$(aptitude -F '%p %v %t' search '~i !~Aunstable' --disable-columns | column -t) ;;
	  esac

	  # Invia al log il contenuto di pkg (se esiste)
	  nome_e_riga "${var} all'archivio \"${release}\""
	  if [ -z "$pkg" ]; then
		 echo "Nessun pacchetto esterno installato" >> "$log" && _error
	  else
		 echo "$pkg" >> "$log" && _ok
	  fi
	  ;;
    lastupd)
      local convdate lastdate file=/var/log/apt/history.log
	  if [ -f "$file" ]; then
		lastdate=$(sed -n '/^Start-Date/h ; $p' "$file" | awk '{print $2}')
		# se il file history.log non contiene la data dell'ultimo aggiornamento, viene utilizzato history.log.1.gz
		[ -z "$lastdate" ] && [ -f "${file}.1.gz" ] && lastdate=$(zcat "${file}.1.gz" | sed -n '/^Start-Date/h ; $p' | awk '{print $2}')

		# variabile che contiene la data in formato "giorno mese anno"
		convdate=$(date -d "$lastdate" '+%d %B %Y')
		
		echo $'\n'"Ultimo aggiornamento del sistema: ${convdate}" >> "$log"
	  fi
	  ;;
	ricercaunica)
	  $_dpkg -l | grep -s1ci $2
	  ;;
    ricercalocale)
      $_dpkg -l | grep -i $2
      ;;
    check)
      _apt "lastupd"
      _common
      _dir "/etc/apt/sources.list.d/"
      _file "/etc/apt/sources.list"
      _comando "$_aptcache policy"
      _comando "$_aptcache stats"
      _comando "$_aptget check"
      _comando "$_dpkg --print-architecture" # uname -m
      _comando "$_aptget update"
      _comando "$_aptget -s -y upgrade"
      _comando "$_aptget -s -y dist-upgrade"
      _comando "$_aptget -s -y -f install"
      _comando "$_aptget -s -y autoremove"
      _comando "$_aptconfig dump"
      _file "/etc/apt/apt.conf"
      _dir "/etc/apt/apt.conf.d/"
      _file "/etc/apt/preferences"
      _dir "/etc/apt/preferences.d/"
      ;;
    *)
      echo "niente"
  esac
}


# Funzione relativa alla gestione dei pacchetti tramite pacman
function _pacman {
  local __pacexe=/usr/bin/pacman
  case $1 in
     lastupd)
       local update=$(awk '/upgraded/ {line=$0;} END { $0=line; gsub(/[\[\]]/,"",$0); printf "%s %s",$1,$2;}' /var/log/pacman.log) #mukimov
       local convdate=$(date -d "$update")
       echo $'\n'"Ultimo aggiornamento del sistema: ${convdate}" >> "$log"
       ;;
     ricercalocale)
       if [ $2 ]; then
         $__pacexe -Q | grep -i $2
       else
         echo "pochi argomenti"
       fi
       ;;
     installati)
       $__pacexe -Qqe
       ;;
     orfani)
       nome_e_riga "Pacchetti orfani"
       _prompt "Verifica orfani"
       $__pacexe -Qqdt &>> "$log" && _ok || _error
       ;;
     check)
       _pacman "lastupd"
       _common
       _comando "/usr/bin/uname -m"
       _comando "/usr/bin/testdb"
       _pack "yaourt"
       _comando "$__pacexe -Syu -p --print-format=" "%r\%n %v"
       _comando "$__pacexe -Qe"
       _pacman "orfani"
       _file "/etc/pacman.conf"
       _file "/etc/pacman.d/mirrorlist"
       ;;
     *)
       echo "niente da fare"
  esac
}

# Funzione per gestire i sistemi che usano portage
function _portage {
  local _emergebin=/usr/bin/emerge
  local _equery=/usr/bin/equery
  case $1 in
	lastupd)
	  local retdate lastdate file=/var/log/emerge.log
	  if [ -f "$file" ]; then
		## Il timestamp dell'ultimo pacchetto installato / aggiornato / rimosso
		lastdate=$(tac /var/log/emerge.log | sed -n '0,/\([0-9]\{10\}\)\:  \*\*\* Finished\. Cleaning up\.\.\./s/\([0-9]\{10\}\)\:  \*\*\* Finished\. Cleaning up\.\.\./\1/p')
		# lastdate=$(grep -i "\*\*\* Finished\. Cleaning up\.\.\." /var/log/emerge.log | awk 'END { print $1 }' | sed 's/\://')
		## Converto in data
		retdate=$(date -d @$lastdate '+%d %B %Y')
		
		echo $'\n'"Ultimo aggiornamento del sistema: ${retdate}" >> "$log"
	  fi
	  ;;
	ricercalocale)
	    if [ $2 ]; then
	      $_equery list "*" | grep $2
	    else
	      echo "aggiungi il nome del pacchetto da cercare come argomento"
	    fi
      	  ;;
    check)
	  _portage "lastupd"
	  _common
	  _comando "$_emergebin --info" # Un sacco di cose utili, incluso il make.conf e l'architettura del sistema (uname -m)
	  _file "/etc/portage/package.use" # USE flags per pacchetto
	  _file "/etc/portage/package.license" # File per includere software closed-source nel sistema
          _file "/etc/portage/package.mask" # File mask
          _file "/etc/portage/package.unmask" # File unmask
	  _file "/etc/portage/package.accept_keywords" # File per unmaskare i pacchetti (il pinning di debian per capirci)
	  _comando "$_emergebin --sync" # Aggiorna il portagethree
	  _comando "$_emergebin -pauND @world" # Lista i pacchetti aggiornabili
	  _comando "$_emergebin -pc" # Lista i pacchetti orfani
	  _comando "$_equery list " "*" # Lista tutti i pacchetti installati
	  _kernel
      ;;
    *)
      echo "specifica un comando per la funzione _portage"
  esac
}

# Scrive il .config del kernel corrente nel log
function _kernel {
    nome_e_riga "Kernel config"
    _prompt "Kernel config"
    zcat /proc/config.gz &>> "$log" && _ok || _error
}

# Funzione relativa a problemi di mount/unmount
function _mount {
  _common
  if [ $INIT != "systemd" ]; then
    _comando "/usr/bin/udisks --dump"
  else
    _comando "/usr/bin/udisksctl dump"
  fi
  _pack "usbmount"
}

# Funzione relativa al funzionamento del touchpad
function _tpad {
  _common
  _pack "xorg"
  _pack "touchpad"
  _pack "synaptics"
  _file "/etc/X11/xorg.conf"
  _dir "/etc/X11/xorg.conf.d/"
  _file "/var/log/Xorg.0.log"
  _comando "/usr/bin/synclient -l" "su"
}

# --------------------------------------------------------------------------
# Funzioni utilizzate per tipo di problema (generiche)
# --------------------------------------------------------------------------

# Stampa la data corrente nel file di log
function _data {
  echo "Log creato il $(date '+%d %B %Y alle %H.%M')" >> "$log"
}

# Funzione che invia il contenuto di un file al file di log
# La funzione va richiamata specificando il path completo del file che sarà assegnato a $1
# Il contenuto dei file viene inviato inalterato al file di log. Se si ha necessità di
# modificare questo comportamento, creare una entry nel ciclo "case"

function _file {
    nome_e_riga "$1"
    _prompt "$1"
    if [ -f "$1" ]; then
	case "$1" in
	    /etc/network/interfaces)
                      # Nasconde nel log gli ESSID e le password criptate contenute in /etc/network/interfaces
		      sed -r "s/((wpa-ssid)|(wpa-psk)).*/\1 \*script-removed\*/" "$1" &>> "$log" && _ok  || _error ;;
	    /var/log/syslog)
		      # se il file contiene la stringa "rsyslogd.*start" ...
		      if [ "$(grep -sci 'rsyslogd.*start$' "$1")" -ne 0 ]; then
			# ... estrae da syslog tutto il contenuto dall'ultima occorrenza della stringa alla fine del file
			sed -n 'H; /rsyslogd.*start$/h; ${g;p;}' "$1" >> "$log" && _ok || _error
		      else
			# se syslog non contiene quella stringa, allora si effettuerà la stessa operazione su syslog.1 ($1.1)
			# in questo caso l'intero contenuto del file syslog viene inviato al log
			cat "$1" &>> "$log" && _ok || _error
			nome_e_riga "$1".1
                        _prompt "$1".1
			sed -n 'H; /rsyslogd.*start$/h; ${g;p;}' "$1".1 >> "$log" && _ok || _error
		      fi ;;
	    *)
		      # per tutti i file non specificati sopra...
		      cat "$1" &>> "$log" && _ok || _error
	esac
    else
      echo "File \"$1\" non trovato" >> "$log" && _error
    fi
}

# Funzione relativa a problemi con le macchine virtuali (VirtualBox)
function _vbox {
	_common
	_prompt "VM logs"
	local vboxhome=/home/$utente/VirtualBox\ VMs
    local state=_ok
    echo
	while [ ! -d "$vboxhome" ]; do
      tput ed
	  _bold "Cartella Virtual Machines non trovata"
      _bold "inserisci il percorso completo (0 per uscire):"
	  read vboxhome
	  if [ "$vboxhome" == "0" ]; then
	    _exit
	  fi
	  tput cuu 3
	done
    
    tput ed
    local menuentries
    local indx=0
	_bold "Macchine virtuali rilevate:"
    for file in "$vboxhome/"*; do
      if [ ! -d "$file" ]; then
        continue
      fi
      menuentries[indx++]="$file"
      echo "     [$indx] $file"
    done
    local numvirt=-1
    while [ $numvirt -lt 0 -o $numvirt -gt $indx ]; do
      tput ed
	  _bold "Inserisci scelta (0 per annullare): "
	  read numvirt
      if [ -z $numvirt ]; then
        numvirt=-1
      fi
      if [ $numvirt == "0" ]; then
        state=_error
        tput cuu 2
        break
      fi
      tput cuu 2
    done
    
    tput cuu $[${#menuentries[*]} + 2]
    tput ed
    if [ "$numvirt" != "0" ]; then
      let numvirt=numvirt-1
      nomevirt=${menuentries[numvirt]}
      _prompt "VM logs per $nomevirt"
    else
      _prompt "VM logs"
    fi

    $state
    if [ "$state" == "_error" ]; then
      return
    fi
    tput cud 1
    for nome_file_logvbox in  "$nomevirt"/Logs/VBox.log*; do
        _file "$nome_file_logvbox"
    done

}

# Invia l'output di un comando al file di log
# La funzione va richiamata specificando il path completo del comando (con eventuali opzioni)
# che sarà assegnato a $1 . L'output dei comandi viene inviato interamente al file di log. Se
# si ha necessità di modificare gli output, creare una entry nel ciclo "case"
#
# Nel caso in cui il comando debba essere eseguito tramite 'su', richiamare la funzione con
# due parametri:
# $1 = la stringa 'su'
# $2 = il comando da eseguire attraverso 'su'

function _comando {
  #local var=${1##*/} 
  #local var2=${1%% *} 
  if [[ $# -eq 2 ]] && [[ "$2" != "su" ]]; then
    local strm="$1\"$2\""
    else
    local strm="$1"
  fi
  local var2=$(echo $1 | awk '{print $1}') # var2 conterrà il comando ($1) privo di eventuali opzioni ma con il path
  local pattern=$(printf '%s\n' "$var2" | sed 's/[[\.*^$/]/\\&/g')
  local res=$(echo $strm | sed "s/^$pattern\b//g")
  local var=$(echo "${var2##*/}${res}") # var conterrà il comando ($1) con le opzioni ma privo del path
  nome_e_riga $strm
  _prompt "$var"
  
  if [ -f "$var2" ]; then # il comando esiste?
      if [[ $# -eq 2 ]] && [[ "$2" == "su" ]]; then # Se vi sono 2 parametri, viene utilizzato "su"
          case "$1" in
              "/usr/bin/synclient -l")
                  # se $DISPLAY è vuota, usa :0 (default per il primo server X)
                  su -c "DISPLAY=${DISPLAY:-:0} $1" "$utente" &>> "$log" _ok || _error ;;
              *)    
                  su -c "$1" "$utente" &>> "$log" && _ok || _error
          esac
      else # non viene utilizzato "su"
          case "$1" in
              # per "iwconfig" e "iwlist scan" gli ESSID non vengono inviati al log
              /sbin/iwconfig)
              (iwconfig | sed -e '/ESSID:/{/off\/any/! s/ESSID:.*/ESSID:"*script-removed*"/g}' -e '/^[ ]*IE: Unknown:.*/d') &>> "$log" && _ok || _error
              ;;
              "/sbin/iwlist scan")
              (iwlist scan | sed -e '/ESSID:.*/{/off\/any/! s/ESSID:.*/ESSID:"*script-removed*"/g}' -e '/^[ ]*IE: Unknown:.*/d') &>> "$log" && _ok || _error
              ;;
                  # nasconde gli ESSID visualizzati da "nmcli dev list"
                  #"/usr/bin/nmcli dev list")
                      #nmcli dev list | sed -r "s/(^AP[[:digit:]]*\.SSID:[[:space:]]*).*/\1\*script removed\*/" >> "$log" && _ok || _error ;;
              *)
              # per tutti gli altri comandi non specificati sopra l'output del comando è inviato inalterato al log
              $1"$2" &>> "$log" && _ok || _error
          esac	  
      fi
  else
      echo "Comando \"${var2}\" non trovato" >> "$log" && _error
  fi
}

# Funzione che stampa solo lo spazio e il nome del comando, prima di eseguirlo
function _prompt {
  echo -n "[ ]  $*"
}

# Funzione che invia il contenuto dei file di una directory al file di log
function _dir {
  nome_e_riga "$1"
  _prompt "$1"

  # Se la directory non esiste, stampa un output sul log ed esce.
  if [ ! -d "$1" ]; then
    echo "La directory non esiste" >> "$log" && _error
    return
  fi

  # Variabili locali
  local file
  # numfile contiene il numero di file contenuti nella directory. Solo primo livello.
  local numfile=$(find "$1" -maxdepth 1 -type f | wc -l)
  # numdir contiene il numero di sottodirectory contenute nella directory. Solo primo livello.
  local numdir=$(find "$1" -maxdepth 1 -type d | wc -l)

  if [ "$numfile" -eq 0 ] && [ "$numdir" -eq 1 ]; then
    echo "La directory è vuota" >> "$log" && _error
  else
    echo "La directory contiene ${numfile} file e $(($numdir - 1)) directory" >> "$log"
    ls -al "$1" >> "$log" && _ok || _error
    # invia al log il contenuto dei file della directory
    for file in "$1"*; do
      if [ -f "$file" ]; then
        nome_e_riga "$file"
        _prompt "$file"
        cat "$file" &>> "$log" && _ok || _error
      fi
    done

    # Funzione che invia al log il contenuto dei file presenti nelle sottodirectory
    # I due cicli for sono separati per permettere l'output di un file subito dopo
    # la directory a cui appartiene
    for file in "$1"*; do
      if [ -d "$file" ]; then
	_dir "$file/"
      fi
    done
  fi
}

# Funzione che elenca i pacchetti installati in base alla parola
# passata come parametro ($1)

function _pack {
  if [ "$2" != "nolog" ]; then
    nome_e_riga "Pacchetti che contengono \"$1\""
  fi
  _prompt "$1"

  # Variabile che contiene i pacchetti trovati
  local packages=$($_packageman "ricercalocale" "$1")

  if [ -z "$packages" ]; then
     if [ "$2" != "nolog" ]; then
       echo "Nessun pacchetto installato" >> "$log" && _error
     else
       _error
     fi
     return 0
  else
     if [ "$2" != "nolog" ]; then
       echo "$packages" >> "$log" && _ok
     else
       _ok
     fi
     return 1
  fi
}

# Funzione che verifica l'esistenza e l'esecuzione di alcuni demoni
# Viene chiamata con due parametri:
# $1 - percorso dell'eseguibile
# $2 - nome da visualizzare
# Se si vuol visualizzare la versione del demone, inserire il comando adatto
# all'interno del ciclo 'case', allo stesso modo specificare al suo interno
# anche il nome dello script d'avvio per fermare, avviare, etc il demone

function _demone {

  # vers = versione del demone ; var = nome dello script d'avvio del demone
  local vers="" var=""
  nome_e_riga "$2"
  _prompt "$2"
  if [ -f "$1" ]; then
    case "$1" in
	/usr/sbin/NetworkManager)
                                  vers=$(NetworkManager --version)
                                  var="network-manager"
                                  ;;
	/usr/sbin/wicd)
                                  vers=$(wicd -h | head -2 | tail -1)
                                  var="wicd"
                                  ;;
    esac
   
    echo "$2 è installato (versione "$vers")" >> "$log" && _ok
    invoke-rc.d "$var" status &>/dev/null
    [ $? -eq 0 ] && echo "$2 è in esecuzione" >> "$log" || echo "$2 non è in esecuzione" >> "$log"
  else
    echo "$2 non è installato" >> "$log" && _error
  fi
}

# --------------------------------------------------------------------------
# Funzioni utilizzate per tipo di problema (particolari)
# --------------------------------------------------------------------------

# comando 'cat /sys/class/dmi/id/{sys_vendor,product_name,product_version,bios_version}'
function _dmi_decode {
  local var="/sys/class/dmi/id/*"
  nome_e_riga "$var"
  _prompt "$var"
  if [ -f /sys/class/dmi/id/sys_vendor ]; then
    echo "Produttore: $(cat /sys/class/dmi/id/sys_vendor)"      &>> "$log"
    echo "Prodotto:   $(cat /sys/class/dmi/id/product_name)"    &>> "$log"
    echo "Versione:   $(cat /sys/class/dmi/id/product_version)" &>> "$log"
    echo "BIOS vers.: $(cat /sys/class/dmi/id/bios_version)"    &>> "$log" && _ok || _error
  else
    echo "File /sys/class/dmi/id/sys_vendor non trovato" >> "$log" && _error
  fi
}

# esistenza di pacchetti contenenti firmware e firmware presente sulla macchina
function _firmware {
  local i var="Firmware"
  _prompt "$var"
  nome_e_riga "$var"
  $_packageman "ricercalocale" "firmware" >> "$log" && _ok || _error
  echo >> "$log"

  # Elenca i file contenuti nelle directory specificate
  for i in "/usr/lib/firmware" "/usr/local/lib/firmware" "/lib/firmware" "/run/udev/firmware-missing"; do
    if [ -d "$i" ]; then
      echo "Contenuto di ${i}" >> "$log"
      ls -al "$i" >> "$log"
    else
      echo "${i} non trovata" >> "$log"
    fi
    echo >> "$log"
  done
}

# Stampa sullo standard output l'eseguibile associato a x-session-manager (il default)
function _x_session_manager {
  update-alternatives --query "x-session-manager" |
    awk '$1 ~ /^Value:$/ { print $2; exit 0 }'
}

# Stampa sullo standard output l'eseguibile associato a x-window-manager (il default)
function _x_window_manager {
  update-alternatives --query "x-window-manager" |
    awk '$1 ~ /^Value:$/ { print $2; exit 0 }'
}

# Stampa la lista dei pacchetti installati che soddisfano una data dipendenza
# con versione (del programma e in Debian) e archivio di provenienza
# Viene chiamata con un parametro:
# $1 - nome della dipendenza
function _soddisfa {
  echo "Installati (${1}):"
  aptitude search '?installed?provides('"$1"')' --disable-columns \
    --display-format "- %p (versione: %v; archivio: %t)"
}

# Restituisce un exit status di 0 solo se l'eseguibile con il nome scelto è in esecuzione da parte dell'utente ($utente)
# Viene chiamata con un parametro:
# $1 - comando di cui controllare l'esecuzione da parte di $utente
function _is_running {
  local list_pids_user list_pids_bin pid pid2
  list_pids_user=$(ps -U "$utente" -o pid) # lista di interi, separati da spazi, con i PID dei processi avviati da $utente
  list_pids_bin=$(pidof -- "$1")           # lista di interi, separati da spazi, con i PID dei processi del comando $1
  for pid in $list_pids_user; do
    for pid2 in $list_pids_bin; do
      if [ "$pid" = "$pid2" ]; then
        return 0  # trovato
      fi
    done
  done
  return 1        # non trovato!
}

# Funzione che "cerca" di ricavare il nome e la versione del DE/WM utilizzato
# manca MATE, LXQT.
function _de_wm {
  nome_e_riga "Desktop Environment - Window Manager"
  _prompt "DE/WM"
  if [ $ID == "debian" ]; then
  {
    # impostazione di default
    echo -n $'Default:\n- x-session-manager: '
    _x_session_manager
    echo -n "- x-window-manager: "
    _x_window_manager
    # installati
    _soddisfa "x-session-manager"
    #_soddisfa "x-window-manager" # non essenziale e impiega già tanto
  } >> "$log"
  fi
  # in esecuzione
  echo -n "In esecuzione: " >> "$log"
  if _is_running "ksmserver"; then kde4-config --version >> "$log" && _ok || _error                         # KDE4
  elif _is_running "gnome-shell"; then gnome-shell --version >> "$log" && _ok || _error                     # Gnome Shell
  elif _is_running "xfdesktop"; then xfce4-about -V | head -n1 | cut -d ' ' -f2- >> "$log" && _ok || _error # Xfce4
  elif _is_running "openbox"; then
    if [ $ID == "debian" && "$(_x_session_manager)" != "/usr/bin/openbox-session" ]; then
      echo -n "(altro x-session-manager) + " >> "$log"                                                                      # Session manager (LXDE?) + Openbox
    fi
    openbox --version | head -n 1 >> "$log" && _ok || _error                                                # Openbox
  else
    echo "Sconosciuto" >> "$log" && _error                                                                          # NON TROVATO
  fi
}

# Funzione che nasconde nel log alcune informazioni sensibili
function _hide {

 # Sostituisce il nome utente e il nome host con 'nomeutente' e 'nomehost' se diversi da [dD]ebian
 [ "$nomehost" != "Debian" ] && [ "$nomehost" != "debian" ] && sed -i -e "s/\b${nomehost}\b/nomehost/g" "$log"
 [ "$utente" != "Debian" ] && [ "$utente" != "debian" ] && sed -i -e "s/\b${utente}\b/nomeutente/g" "$log"

 # Nasconde gli ESSID gestiti attraverso Network Manager
 local var file mydir="/etc/NetworkManager/system-connections/"

 if [ -d "$mydir" ]; then # se esiste la directory /etc/NetworkManager/system-connections/ ...
    for file in "$mydir"/*; do # ciclo attraverso il contenuto della directory
       if [ -f "$file" ]; then # se l'elemento è un file...
          var=$(sed -n "s/ssid=//p" "$file") # ... var conterrà l'eventuale ESSID...
          if [ -n "$var" ]; then # ... e se è diverso dalla stringa vuota...
             sed -i "s/${var}/\*script-removed\*/g" "$log" # ... lo nasconde nel file di log
          fi
       fi
    done
 fi

 # Nasconde nel log i i nomi delle connessioni gestite da NetworkManager
 sed -i -r "s/(NetworkManager.*keyfile.*((parsing)|(read connection))).*/\1 \*script-removed\*/" "$log"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

clear
_osprobe
_intro
_avvertenze
_check
_scelta
_hide
_upload
_exit
