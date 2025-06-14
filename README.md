PoliDAO
Decentralized On-Chain Governance & Crowdfunding Protocol

1. Opis Projektu
PoliDAO to innowacyjny projekt inteligentnych kontraktów, który umożliwia budowanie decentralizowanych, on-chainowych mechanizmów zarządzania (governance) oraz transparentnych zbiórek publicznych (crowdfunding) w ekosystemie blockchain. Inspirując się funkcjonalnościami parlamentarnymi, PoliDAO pozwala użytkownikom na tworzenie i głosowanie nad propozycjami oraz inicjowanie i wspieranie kampanii społecznych za pomocą tokenów ERC-20.

Celem PoliDAO jest stworzenie w pełni transparentnego, zdecentralizowanego i odpornego na manipulacje ekosystemu, który demokratyzuje procesy decyzyjne i finansowania inicjatyw obywatelskich.

2. Główne Funkcjonalności
Kontrakt PoliDAO jest podzielony na dwa kluczowe moduły, zapewniające wszechstronne narzędzia do zarządzania i finansowania.

Moduł Głosowania
Tworzenie Propozycji: Każdy uprawniony użytkownik może przedstawić nową propozycję do głosowania, definiując jej treść (question) oraz czas trwania głosowania (durationSeconds).
Głosowanie: Uczestnicy mogą oddawać głosy "za" (true) lub "przeciw" (false) wybranej propozycji. System zapewnia, że każdy adres może zagłosować tylko raz na daną propozycję.
Weryfikacja Wyników: Po zakończeniu okresu głosowania, wyniki (liczba głosów "za" i "przeciw") są publicznie dostępne i trwale zapisane w blockchainie.
Transparentność: Wszystkie propozycja i ich wyniki są w pełni transparentne i audytowalne.
Moduł Zbiórek Publicznych
Biała Lista Tokenów: Właściciel kontraktu (Ownable) ma możliwość zarządzania białą listą tokenów ERC-20, które mogą być akceptowane w zbiórkach, co zwiększa bezpieczeństwo i kontrolę nad rodzajem przyjmowanych aktywów.
Prowizje: Kontrakt implementuje mechanizmy pobierania prowizji:
donationCommission: Prowizja naliczana od każdej wpłaty na zbiórkę.
successCommission: Prowizja naliczana od wypłacanych środków przez twórcę zbiórki. Obie prowizje są konfigurowalne przez właściciela kontraktu i są przekazywane na dedykowany commissionWallet.
Tworzenie Kampanii: Użytkownicy mogą inicjować nowe zbiórki, określając:
Adres tokena ERC-20 (token)
Cel zbiórki (target)
Czas trwania (durationSeconds)
Typ zbiórki: isFlexible (elastyczna) lub sztywna.
Wpłaty: Każdy może wpłacić środki na zbiórkę za pomocą whitelisted tokenów ERC-20.
Typy Zbiórek:
Zbiórki Elastyczne (isFlexible=true): Twórca zbiórki może wypłacić zebrane środki w dowolnym momencie, niezależnie od osiągnięcia celu.
Zbiórki Sztywne (isFlexible=false): Twórca zbiórki może wypłacić środki tylko po osiągnięciu zadanego celu. Jeśli cel nie zostanie osiągnięty, darczyńcy mogą żądać zwrotu swoich wpłat.
Mechanizm Zwrotu (refund): W przypadku zbiórek sztywnych, jeśli cel nie zostanie osiągnięty, darczyńcy mają możliwość odzyskania swoich wpłaconych środków w określonym oknie czasowym (RECLAIM_PERIOD), które jest inicjowane przez twórcę zbiórki (initiateClosure).
Wypłaty (withdraw): Twórcy zbiórek mogą wypłacić zebrane fundusze, z uwzględnieniem typu zbiórki i naliczenia prowizji.
3. Zalety Rozwiązania On-Chain
Transparentność: Wszystkie operacje (tworzenie, głosowanie, wpłaty, wypłaty, prowizje) są publicznie widoczne i weryfikowalne w blockchainie.
Niezmienność: Dane zapisane w blockchainie są trwałe i nie mogą zostać zmienione ani usunięte, zapewniając integralność historyczną.
Bezpieczeństwo: Wykorzystanie kryptograficznych mechanizmów blockchaina i sprawdzonych bibliotek (OpenZeppelin) minimalizuje ryzyko manipulacji i ataków.
Potencjalna Decentralizacja: Kontrakt stanowi solidną bazę dla budowy pełnoprawnej Decentralizowanej Autonomicznej Organizacji (DAO), gdzie zarządzanie może być w przyszłości delegowane na społeczność.
Odporność na Cenzurę: Dostęp do funkcji głosowania i zbiórek jest niezależny od pojedynczych scentralizowanych podmiotów.
4. Architektura Kontraktu
Kontrakt PoliDAO.sol wykorzystuje:

Ownable (OpenZeppelin): Do zarządzania prawami właścicielskimi, umożliwiając właścicielowi kontrolę nad kluczowymi parametrami (np. biała lista tokenów, prowizje).
IERC20 (OpenZeppelin): Do bezpiecznej interakcji z tokenami ERC-20 (transfery, sprawdzanie salda).
Struktury danych: Proposal i Fundraiser przechowują szczegółowe informacje o każdej propozycji i zbiórce.
Mapowania: Używane do efektywnego przechowywania danych (np. proposals, fundraisers, hasVoted, donations, refunded, isTokenWhitelisted).
Zmienne stanu: proposalCount, fundraiserCount, donationCommission, successCommission, commissionWallet, RECLAIM_PERIOD definiują globalne parametry protokołu.
Zdarzenia (Events): Emitowane w celu ułatwienia monitorowania aktywności kontraktu poza łańcuchem (np. przez interfejsy użytkownika).
5. Instalacja i Uruchomienie
Wymagania
Aby skompilować, testować i wdrożyć kontrakty, potrzebujesz zainstalować:

Node.js (wersja LTS)
npm (z Node.js) lub Yarn
Hardhat (zalecane środowisko deweloperskie dla Solidity)
Klonowanie Repozytorium
Bash

git clone https://github.com/TwojeNazwaUzytkownika/PoliDAO.git
cd PoliDAO
Instalacja Zależności
Zainstaluj wszystkie zależności projektu, w tym Hardhat i biblioteki OpenZeppelin:

Bash

npm install
# lub
yarn install
6. Kompilacja Kontraktów
Aby skompilować inteligentne kontrakty Solidity:

Bash

npx hardhat compile
Wynikowe pliki JSON (ABI i bytecode) znajdziesz w katalogu artifacts/.

7. Testowanie Kontraktów
Projekt zawiera obszerny zestaw testów, które zapewniają stabilność i poprawność działania kontraktu PoliDAO. Zaleca się uruchomienie testów przed każdym wdrożeniem.

Aby uruchomić testy:

Bash

npx hardhat test
8. Deployment Kontraktów
Plik scripts/deploy.js zawiera skrypt do wdrożenia kontraktu PoliDAO na wybranej sieci blockchain.

Konfiguracja:

Upewnij się, że plik hardhat.config.js jest poprawnie skonfigurowany dla docelowej sieci (np. sepolia, mainnet). Będziesz potrzebować adresu RPC sieci i klucza prywatnego konta deployera (przechowywanego bezpiecznie, np. w pliku .env).
Zdefiniuj zmienne środowiskowe dla klucza prywatnego i adresu RPC, np. w pliku .env:
PRIVATE_KEY="twój_klucz_prywatny"
ALCHEMY_API_KEY="twój_klucz_alchemy_lub_infura" # Lub inny dostawca RPC
Upewnij się, że adres właściciela i portfel prowizji w skrypcie deploy.js są prawidłowe.
Uruchomienie deploymentu:

Bash

npx hardhat run scripts/deploy.js --network <nazwa_sieci>
Przykład dla sieci Sepolia:

Bash

npx hardhat run scripts/deploy.js --network sepolia
Po pomyślnym wdrożeniu, w konsoli zostanie wyświetlony adres wdrożonego kontraktu.

9. Interakcja z Kontraktem
Możesz wchodzić w interakcje z kontraktem PoliDAO za pomocą bibliotek takich jak Ethers.js lub Web3.js. Poniżej prosty przykład użycia Ethers.js:

JavaScript

const { ethers } = require("ethers");
const PoliDAO_ABI = require("./artifacts/contracts/PoliDAO.sol/PoliDAO.json").abi;

// Ustawienie providera (np. Alchemy, Infura, lokalny Node)
const provider = new ethers.JsonRpcProvider("https://sepolia.infura.io/v3/YOUR_INFURA_PROJECT_ID");
// LUB
// const provider = new ethers.JsonRpcProvider("http://127.0.0.1:8545/"); // Lokalny Hardhat node

const contractAddress = "0x..."; // Wklej tutaj adres swojego wdrożonego kontraktu PoliDAO
const privateKey = "YOUR_PRIVATE_KEY"; // Klucz prywatny do podpisywania transakcji
const wallet = new ethers.Wallet(privateKey, provider);

const poliDAO = new ethers.Contract(contractAddress, PoliDAO_ABI, wallet);

async function exampleInteraction() {
    try {
        // Przykład: Tworzenie propozycji
        const tx = await poliDAO.createProposal("Czy zgadzasz się na to?", 3600); // 1 godzina
        await tx.wait();
        console.log("Propozycja stworzona, TX:", tx.hash);

        // Przykład: Pobieranie danych o propozycji
        const proposal = await poliDAO.getProposal(1);
        console.log("Propozycja 1:", proposal);

        // Przykład: Głosowanie
        // const voteTx = await poliDAO.vote(1, true); // Głosuj za propozycją 1
        // await voteTx.wait();
        // console.log("Zagłosowano, TX:", voteTx.hash);

        // Przykład: Whitelistowanie tokena (tylko właściciel)
        // const tokenAddress = "0x...TwójAdresTokenaERC20...";
        // const whitelistTx = await poliDAO.whitelistToken(tokenAddress);
        // await whitelistTx.wait();
        // console.log("Token whitelisted, TX:", whitelistTx.hash);

        // Przykład: Tworzenie zbiórki (wymaga whitelisted tokena)
        // const fundraiserTx = await poliDAO.createFundraiser(tokenAddress, ethers.parseUnits("1000", 18), 7 * 24 * 3600, false); // 1000 tokenów, 7 dni, sztywna
        // await fundraiserTx.wait();
        // console.log("Zbiórka stworzona, TX:", fundraiserTx.hash);

    } catch (error) {
        console.error("Błąd interakcji z kontraktem:", error);
    }
}

// exampleInteraction();
10. Audyt Bezpieczeństwa
Kod kontraktu został stworzony z myślą o bezpieczeństwie, wykorzystując sprawdzone wzorce i biblioteki OpenZeppelin. Niemniej jednak, przed wdrożeniem na produkcję, zawsze zaleca się przeprowadzenie niezależnego audytu bezpieczeństwa przez doświadczonych specjalistów w dziedzinie smart kontraktów.

11. Licencja
Ten projekt jest objęty licencją MIT. Więcej informacji znajdziesz w pliku LICENSE.

12. Wkład
Wszelki wkład jest bardzo mile widziany! Jeśli masz pomysły na ulepszenia, zgłoś błąd lub chciałbyś dodać nową funkcjonalność, proszę otwórz Issue lub Pull Request.