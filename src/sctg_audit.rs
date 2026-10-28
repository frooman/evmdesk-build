//! SCTG: события журнала подключений от клиента-оператора (инициатора).
//!
//! Зачем: hbbs при создании события `new` не знает, КТО подключается (в его запросе
//! есть только ID цели), поэтому в журнале пусто, пока цель не приняла вызов и не
//! появилась запись. Клиент-оператор знает свой ID и цель — шлём `new` сразу при
//! старте подключения, а `close` при закрытии сессии (если цель/hbbr не прислали).
//!
//! Контракт apimain: POST /api/audit/conn, поля
//!   { action: "new"|"close", id: <ID цели>, peer: [<ID оператора>], session_id }
//! Сервер склеивает событие с hbbs-записью того же peer_id (HandleNew/HandleClose).

use hbb_common::config::{Config, LocalConfig};
use hbb_common::log;
use serde_json::json;

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

/// Начало подключения: «кто инициировал» виден в журнале сразу, до подтверждения цели.
pub fn post_new(target_id: &str) {
    post("new", target_id, 0);
}

/// Завершение сессии со стороны оператора — закрывает запись, даже если close от цели/hbbr не пришёл.
pub fn post_close(target_id: &str, session_id: u64) {
    post("close", target_id, session_id);
}
