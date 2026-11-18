# Мониторинг Java-приложения в Kubernetes

Учебный проект для развёртывания Spring Boot-приложения в Kubernetes и проверки трёх направлений наблюдаемости: **метрик**, **трассировки запросов** и **централизованного сбора логов**.

Приложение предоставляет HTTP-методы для управляемой нагрузки на CPU, Heap и сборщик мусора. Метрики собираются через Micrometer/Prometheus и отображаются в Grafana; трассы экспортируются по OTLP в Jaeger; логи контейнера направляются Fluentd в Elasticsearch и просматриваются через Kibana.

- **Исходный код и конфигурации:** [GitHub — MalskyKirill/grafana-demo](https://github.com/MalskyKirill/grafana-demo)
- **Готовый контейнер:** [Docker Hub — malskykirill/grafana-demo](https://hub.docker.com/r/malskykirill/grafana-demo), тег `1.1`
- **Среда экспериментов:** [Killercoda Kubernetes Playground](https://killercoda.com/playgrounds/scenario/kubernetes)

## Используемые технологии

| Компонент | Назначение | Версия / реализация |
|---|---|---|
| Java / Spring Boot | HTTP-приложение и Actuator | Java 21, Spring Boot 4.1.2 |
| Micrometer | Метрики JVM и приложения | `micrometer-registry-prometheus` |
| Prometheus | Сбор временных рядов | v3.16.0 |
| Grafana | Дашборды и правило оповещения | Helm chart `grafana-community/grafana` |
| OpenTelemetry / Jaeger | Экспорт и просмотр трасс | Jaeger 2.23.0 |
| Fluentd | Сбор логов контейнера | `v1.19.3-debian-elasticsearch8-1.1` |
| Elasticsearch / Kibana | Индексация и просмотр логов | 8.19.25 |
| Kubernetes / Helm | Развёртывание стенда | тестировалось в Killercoda |

## Архитектура

~~~text
                      +-------------------+
                      | Spring Boot       |
                      | grafana-demo:8080 |
                      +---------+---------+
                                |
               +----------------+----------------+
               |                |                |
        /actuator/prometheus   OTLP         stdout / CRI logs
               |                |                |
         +-----v-----+    +-----v-----+    +-----v-----+
         | Prometheus|    |   Jaeger  |    |   Fluentd |
         +-----+-----+    +-----------+    +-----+-----+
               |                                 |
         +-----v-----+                     +-----v---------+
         |  Grafana  |                     | Elasticsearch |
         | + alerting|                     +-----+---------+
         +-----------+                           |
                                           +-----v-----+
                                           |  Kibana   |
                                           +-----------+
~~~

Все ресурсы Kubernetes размещаются в namespace `monitoring`. Для двухузлового окружения Killercoda мониторинг и EFK удобно развёртывать **в отдельных сессиях**: одновременный запуск Elasticsearch, Kibana, Grafana и Jaeger может исчерпать оперативную память.

## Структура репозитория

~~~text
.
├── Dockerfile
├── pom.xml
├── mvnw
├── setup.sh                  # Spring Boot + Prometheus + Grafana
├── setup-efk.sh              # Spring Boot + Elasticsearch + Fluentd + Kibana
├── src/main/
│   ├── java/ru/mephi/grafana_demo/
│   │   └── LoadController.java
│   └── resources/application.properties
└── k8s/
    ├── app.yaml
    ├── prometheus.yaml
    ├── grafana-values.yaml
    ├── jaeger.yaml
    ├── elasticsearch.yaml
    ├── fluentd.yaml
    ├── kibana.yaml
    └── dashboards/
        ├── java-application-monitoring.json
        └── jvm-micrometer-4701.json
~~~

Манифесты и значения Helm: [каталог k8s](./k8s). Оба JSON-дашборда загружаются автоматически через ConfigMap и sidecar Grafana.

## Быстрый запуск: метрики и Grafana

Требуются доступный кластер Kubernetes, `kubectl`, `helm`, `git` и возможность скачать контейнерные образы.

В новой сессии Killercoda:

~~~bash
git clone https://github.com/MalskyKirill/grafana-demo.git
cd grafana-demo
bash setup.sh
kubectl get pods -n monitoring
~~~

Скрипт разворачивает приложение, Prometheus и Grafana, подключает Prometheus в качестве источника данных, создаёт два дашборда и применяет правило `JVM Heap Usage Above 80%`. При первом запуске скачивание образов и готовность Pod могут занять некоторое время.

Для открытия Grafana в отдельной вкладке терминала Killercoda:

~~~bash
kubectl port-forward -n monitoring --address 0.0.0.0 svc/grafana 3000:80
~~~

Откройте порт **3000** через интерфейс Traffic / Ports Killercoda. Логин — `admin`, пароль читается из Kubernetes Secret:

~~~bash
kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
~~~

Пароль не следует сохранять в репозитории.

В Grafana доступны:

1. **Java Application Monitoring** — используемая Heap-память, загрузка CPU и число GC-пауз за скользящее окно.
2. **JVM (Micrometer) - 4701 (adapted)** — адаптация [дашборда № 4701](https://grafana.com/grafana/dashboards/4701/) для Prometheus и меток приложения. Отдельные панели исходного шаблона могут не получать данные из-за различий версий Micrometer.

Метрики приложения: `/actuator/prometheus`. Prometheus опрашивает сервис раз в 10 секунд (см. [prometheus.yaml](./k8s/prometheus.yaml)).

## HTTP-интерфейс нагрузочных экспериментов

| Метод и путь | Действие |
|---|---|
| `GET /api/load/cpu` | Вычислительная нагрузка на CPU в течение ~2 секунд |
| `POST /api/load/gc` | Создание 1000 временных массивов по 256 КиБ (~250 МиБ выделений) |
| `POST /api/load/memory` | Удержание дополнительных 16 МиБ памяти за один запрос, максимум 64 МиБ |
| `DELETE /api/load/memory` | Удаление ссылок на удерживаемые массивы |

Например, из Kubernetes можно отправить запрос на генерацию GC-нагрузки:

~~~bash
kubectl run gc-test -n monitoring --image=curlimages/curl --restart=Never -- \
  curl -sS -X POST http://grafana-demo:8080/api/load/gc

kubectl logs -n monitoring gc-test
~~~

После завершения временные Pod можно удалить командой `kubectl delete pod gc-test -n monitoring`.

### Проверка алерта на Heap > 80%

В [grafana-values.yaml](./k8s/grafana-values.yaml) задано правило с порогом **80%**, интервалом проверки **10 секунд** и ожиданием **30 секунд**. Процент рассчитывается как сумма используемой Heap-памяти, делённая на сумму максимальных размеров Heap-пулов.

Для лабораторного эксперимента максимальный размер Heap временно изменялся с 256 до **112 МиБ**:

~~~bash
kubectl set env deployment/grafana-demo -n monitoring JAVA_TOOL_OPTIONS="-Xms64m -Xmx112m"
kubectl rollout status deployment/grafana-demo -n monitoring --timeout=180s
~~~

Затем выполнялись четыре последовательных `POST /api/load/memory` с контролем ответа и состояния Pod после каждого запроса. При достижении примерно **87%** правило перешло в `Firing`. Нагрузка намеренно ограничена: при малом Heap возможен `OutOfMemoryError`.

После эксперимента память освобождалась запросом `DELETE /api/load/memory`, затем возвращалась исходная конфигурация JVM:

~~~bash
kubectl set env deployment/grafana-demo -n monitoring JAVA_TOOL_OPTIONS="-Xms128m -Xmx256m"
kubectl rollout status deployment/grafana-demo -n monitoring --timeout=180s
~~~

После восстановления приложения статус алерта вернулся в `Normal`. Изменение параметров командой `kubectl set env` относится к текущему кластеру; в [app.yaml](./k8s/app.yaml) по умолчанию сохранён `-Xmx256m`.

## Jaeger: трассировка запросов

Сначала разверните Jaeger в кластере с уже запущенным приложением:

~~~bash
kubectl apply -f k8s/jaeger.yaml
kubectl rollout status deployment/jaeger -n monitoring --timeout=180s
~~~

Приложение в Kubernetes настроено на OTLP HTTP: `http://jaeger.monitoring.svc.cluster.local:4318/v1/traces`. Чтобы открыть UI, в отдельном терминале:

~~~bash
kubectl port-forward -n monitoring --address 0.0.0.0 svc/jaeger 16686:16686
~~~

Откройте порт **16686** через Traffic / Ports Killercoda. Для проверки можно выполнить запросы к `GET /api/load/cpu` и выбрать сервис `grafana-demo` в Jaeger Search.

В выполненном эксперименте в Jaeger была обнаружена трасса `GET /api/load/cpu` продолжительностью **2,0 с**, со статусом HTTP 200. Трассировка проверена на одном сервисе (один спан), без межсервисных переходов.

При запуске `setup.sh` Jaeger автоматически **не** устанавливается; его необходимо развернуть отдельно. Пока Jaeger отсутствует, в логах приложения могут появляться ошибки экспорта трасс.

## EFK: сбор и просмотр логов

В **отдельной новой сессии Killercoda**:

~~~bash
git clone https://github.com/MalskyKirill/grafana-demo.git
cd grafana-demo
bash setup-efk.sh
kubectl get pods -n monitoring
~~~

Скрипт устанавливает приложение, Elasticsearch, Fluentd (DaemonSet на узлах) и Kibana. Fluentd читает файлы `/var/log/containers/grafana-demo-*_monitoring_*.log` и отправляет документы в индекс вида `logstash-YYYY.MM.DD`. В Elasticsearch отключён `mmap` для учебного стенда.

Проверка индексов:

~~~bash
kubectl run es-check -n monitoring --image=curlimages/curl --restart=Never -- \
  curl -sS 'http://elasticsearch:9200/_cat/indices?v'
kubectl logs -n monitoring es-check
~~~

В ходе эксперимента в индексе `logstash-2026.11.18` было обнаружено более **2000** документов. В `_source` присутствовали поля `message`, `@timestamp` и `kubernetes.container_name`, подтверждающие происхождение записей из `grafana-demo`. Для одного узла Elasticsearch статус `yellow` ожидаем при одной незапущенной реплике: основной шард при этом доступен.

Для Kibana откройте порт 5601:

~~~bash
kubectl port-forward -n monitoring --address 0.0.0.0 svc/kibana 5601:5601
~~~

В разделе **Stack Management → Data Views** создайте:

- **Name:** `Spring Boot logs`
- **Index pattern:** `logstash-*`
- **Timestamp field:** `@timestamp`

Далее откройте **Discover** и примените KQL:

~~~text
kubernetes.container_name: "grafana-demo"
~~~

Для удобства добавьте в таблицу поля `@timestamp`, `message`, `kubernetes.pod_name`. В выполненном эксперименте Kibana отображала более **1000** документов приложения за выбранный 15-минутный интервал.

### Ограничения памяти Killercoda

При одновременном запуске компонентов EFK на узле `controlplane` доступная память уменьшалась примерно до **90 МиБ**, а `kubectl` отвечал ошибкой `TLS handshake timeout`. Основной дополнительной нагрузкой оказалась Kibana.

Для восстановления временно применялось:

~~~bash
kubectl scale deployment/kibana -n monitoring --replicas=0
~~~

После освобождения памяти параметр Node.js Heap Kibana уменьшался и Pod запускался повторно:

~~~bash
kubectl set env deployment/kibana -n monitoring NODE_OPTIONS="--max-old-space-size=512"
kubectl scale deployment/kibana -n monitoring --replicas=1
kubectl rollout status deployment/kibana -n monitoring --timeout=180s
~~~

Это настройка **для воспроизведения учебного эксперимента**, а не рекомендуемая конфигурация Kibana для эксплуатации. В [kibana.yaml](./k8s/kibana.yaml) исходное значение остаётся `768`. Уменьшение Heap Node.js не ограничивает всю память процесса.

## Локальная сборка

Для сборки требуется Java 21 и Docker (в репозитории есть Maven Wrapper):

~~~bash
./mvnw clean package
docker build -t grafana-demo:local .
docker run --rm -p 8080:8080 grafana-demo:local
~~~

При локальном запуске экспорт трасс по OTLP по умолчанию отключён. Эндпоинт метрик: `http://localhost:8080/actuator/prometheus`.

В Kubernetes используется опубликованный образ [`malskykirill/grafana-demo:1.1`](https://hub.docker.com/r/malskykirill/grafana-demo/tags).

## Основные конфигурации

| Файл | Назначение |
|---|---|
| [`k8s/app.yaml`](./k8s/app.yaml) | Namespace, Deployment и Service приложения, probes, ресурсы и настройки JVM |
| [`k8s/prometheus.yaml`](./k8s/prometheus.yaml) | Конфигурация сбора метрик и Prometheus Deployment |
| [`k8s/grafana-values.yaml`](./k8s/grafana-values.yaml) | Helm-настройки, источники данных, alert rule и загрузка дашбордов |
| [`k8s/dashboards/`](./k8s/dashboards) | JSON двух дашбордов Grafana |
| [`k8s/jaeger.yaml`](./k8s/jaeger.yaml) | Jaeger Deployment и Service |
| [`k8s/elasticsearch.yaml`](./k8s/elasticsearch.yaml) | Одноузловой Elasticsearch без постоянного хранилища |
| [`k8s/fluentd.yaml`](./k8s/fluentd.yaml) | RBAC, парсер CRI и DaemonSet сборщика логов |
| [`k8s/kibana.yaml`](./k8s/kibana.yaml) | Kibana Deployment и Service |

## Ограничения и особенности стенда

- Приложение, Grafana и Elasticsearch в Killercoda работают без постоянного хранилища; после завершения сессии состояние теряется.
- Значения запросов и тестовые результаты зависят от нагрузки и конфигурации JVM; численные результаты выше относятся к проведённым экспериментам.
- В лабораторном режиме отключена защита Elasticsearch, поэтому манифесты **не предназначены для открытого продакшен-развёртывания**.
- Опубликованные HTTP-методы генерации нагрузки предназначены для тестов и не должны использоваться в публично доступном сервисе.
- Для воспроизводимости дашборды сохранены в JSON, конфигурация развёртывания — в YAML, а образы — в публичном Docker Hub.

## Ссылки

- [Репозиторий GitHub](https://github.com/MalskyKirill/grafana-demo)
- [Docker Hub: образ grafana-demo](https://hub.docker.com/r/malskykirill/grafana-demo)
- [Исходный дашборд JVM (Micrometer), ID 4701](https://grafana.com/grafana/dashboards/4701/)
- [Killercoda Kubernetes Playground](https://killercoda.com/playgrounds/scenario/kubernetes)
