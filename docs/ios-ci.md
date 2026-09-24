# Сборка .ipa через GitHub Actions + подпись через Sideloadly

## Почему не подписываем прямо в CI

Пробовали подписывать `.ipa` прямо в GitHub Actions через fastlane
(`cert`/`sigh`/`match`) — они используют публичный Apple Developer Portal
API, который бесплатные (без $99/год Apple Developer Program) Apple ID
пускает через веб/Xcode, но не через этот API headless — попытки логина
стабильно падали с "invalid username and password", даже с валидной
`FASTLANE_SESSION`.

При этом ты и раньше успешно собирал `.ipa` с бесплатным Apple ID через
**Sideloadly** — она работает, потому что использует не этот API, а
приватный протокол авторизации Apple (Anisette), тот же, что использует сам
Xcode. Так что схема такая:

- **GitHub Actions** — только компилирует Swift-код в `.app` и упаковывает
  его в `.ipa` **без подписи** (просто `Payload/PhoneVR.app` в zip).
- **Sideloadly, локально у тебя** — подписывает этот `.ipa` твоим Apple ID
  и устанавливает на iPhone. Так же, как ты делал раньше.

Плюс: из GitHub Secrets полностью пропадает необходимость держать
Apple-пароли/сессии — CI ничего не знает про твой Apple ID.

## Как получить .ipa

1. Actions → "Build unsigned iOS .ipa" → Run workflow (или просто запушь
   изменения в `ios-client/**`, тогда соберётся автоматически).
2. Когда сборка позеленеет, зайди в неё → Artifacts → скачай
   `PhoneVR-unsigned-ipa` (там `PhoneVR-unsigned.ipa`).

## Установка на iPhone через Sideloadly

1. Открой Sideloadly на Windows, подключи iPhone (USB или по WiFi, если уже
   настроено).
2. Перетащи скачанный `PhoneVR-unsigned.ipa` в Sideloadly.
3. Укажи свой Apple ID, как обычно.
4. Sideloadly сама подпишет `.ipa` и поставит на телефон.

Ограничение то же, что и раньше при бесплатном Apple ID: подписанное
приложение живёт **7 дней**, потом надо переустановить (Sideloadly умеет
делать это заново за секунды — пересборка в GitHub Actions при этом не
нужна, если код не менялся, можно просто заново скормить тот же .ipa).

## Когда всё-таки может понадобиться $99/год

Если хочется, чтобы весь процесс (сборка **и** подпись) был автоматическим
в CI, без Sideloadly и без переустановки каждые 7 дней — тогда нужен платный
Apple Developer Program: с ним `cert`/`sigh`/`match` в GitHub Actions
работают штатно (это официально поддерживаемый API-путь), и профиль живёт
год.
