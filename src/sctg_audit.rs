//! SCTG: события журнала подключений от клиента-оператора (инициатора).
//!
//! Зачем: hbbs при создании события `new` не знает, КТО подключается (в его запросе
//! есть только ID цели), поэтому в журнале пусто, пока цель не приняла вызов и не
//! появилась запись. Клиент-оператор знает свой ID и цель — шлём `new` сразу при
//! старте подключения, `update` (heartbeat) каждые 30 секунд и `close` при закрытии.
//!
//! Зачем heartbeat: direct-сессии идут P2P мимо сервера, и `close` при закрытии окна
//! может не дойти. Сервер (apimain) по `update` продлевает `last_seen`; 90 секунд
//! тишины → сессия закрывается сама (CloseStale) с временем последнего heartbeat.
//!
//! Контракт apimain: POST /api/audit/conn, поля
//!   { action: "new"|"close"|"", id: <ID цели>, peer: [<ID оператора>], session_id }
//! Пустой action — обновление (heartbeat). Сервер склеивает события с hbbs-записью
//! того же peer_id (HandleNew/HandleUpdate/HandleClose).

use hbb_common::config::{Config, LocalConfig};
use hbb_common::log;
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Сколько ждать между heartbeat-ами. Сервер закрывает сессию после 90 с тишины,
/// поэтому 30 с даёт трёхкратный запас на сетевые задержки.
const HEARTBEAT_SECS: u64 = 30;

lazy_static::lazy_static! {
    /// Активные heartbeat-потоки: ID цели → флаг остановки.
    static ref HEARTBEATS: Mutex<HashMap<String, Arc<AtomicBool>>> = Mutex::new(HashMap::new());
}

fn audit_url() -> String {
    crate::get_audit_server(
        Config::get_option("api-server"),
        Config::get_option("custom-rendezvous-server"),
        "conn".to_owned(),
    )
}

/// Отправка события, если клиент авторизован (есть access_token) и цель известна.
fn post(action: &str, target_id: &str, session_id: u64) {
    if target_id.is_empty() || LocalConfig::get_option("access_token").is_empty() {
        return;
    }
    let my_id = Config::get_id();
    if my_id.is_empty() || my_id == target_id {
        return;
    }
    let url = audit_url();
    if url.is_empty() {
        return;
    }
    let body = json!({
        "action": action,
        "id": target_id,
        "peer": [my_id],
        "session_id": session_id,
        "uuid": crate::encode64(hbb_common::get_uuid()),
    })
    .to_string();
    std::thread::spawn(move || {
        let rt = match hbb_common::tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                log::debug!("sctg audit: runtime failed: {}", e);
                return;
            }
        };
        if let Err(e) = rt.block_on(crate::post_request(url, body, "")) {
            log::debug!("sctg audit: post failed: {}", e);
        }
    });
}

/// Запуск heartbeat для цели: продлевает сессию на сервере, пока она жива.
fn start_heartbeat(target_id: &str) {
    if target_id.is_empty() || LocalConfig::get_option("access_token").is_empty() {
        return;
    }
    let stop = Arc::new(AtomicBool::new(false));
    {
        let mut map = match HEARTBEATS.lock() {
            Ok(m) => m,
            Err(_) => return,
        };
        if let Some(old) = map.insert(target_id.to_owned(), stop.clone()) {
            old.store(true, Ordering::Relaxed);
        }
    }
    let target = target_id.to_owned();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(std::time::Duration::from_secs(HEARTBEAT_SECS));
            if stop.load(Ordering::Relaxed) {
                break;
            }
            post("", &target, 0);
        }
        // поток завершается — убираем себя из реестра (если запись всё ещё наша)
        if let Ok(mut map) = HEARTBEATS.lock() {
            if let Some(cur) = map.get(&target) {
                if Arc::ptr_eq(cur, &stop) {
                    map.remove(&target);
                }
            }
        }
    });
}

/// Остановка heartbeat для цели (сессия завершена).
fn stop_heartbeat(target_id: &str) {
    if let Ok(mut map) = HEARTBEATS.lock() {
        if let Some(stop) = map.remove(target_id) {
            stop.store(true, Ordering::Relaxed);
        }
    }
}

/// Начало подключения: «кто инициировал» виден в журнале сразу, до подтверждения цели.
/// Заодно запускаем heartbeat — сервер будет знать, что сессия жива, даже при direct (P2P).
pub fn post_new(target_id: &str) {
    post("new", target_id, 0);
    start_heartbeat(target_id);
}

/// Завершение сессии со стороны оператора — закрывает запись, даже если close от цели/hbbr не пришёл.
pub fn post_close(target_id: &str, session_id: u64) {
    stop_heartbeat(target_id);
    post("close", target_id, session_id);
}
