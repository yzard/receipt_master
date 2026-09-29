use receipt_backend_api::{State, application, config::Config};
use std::{env, path::PathBuf, time::Duration};
use tokio::sync::watch;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 || args[1] != "--data-dir" {
        return Err("Usage: receipt-backend-api --data-dir ABSOLUTE_DIRECTORY".into());
    }
    let root = PathBuf::from(&args[2]);
    if !root.is_absolute() || !root.is_dir() {
        return Err("Data directory must be an existing absolute directory".into());
    }
    let ocr_url = optional_env("BACKEND_OCR_URL")?;
    let ocr_api_key = optional_env("BACKEND_OCR_API_KEY")?;
    let config = Config::parse_with_ocr_overrides(
        &tokio::fs::read_to_string(root.join("config.toml")).await?,
        ocr_url.as_deref(),
        ocr_api_key.as_deref(),
    )?;
    let address = (config.general.host, config.general.port);
    let database_root = root.clone();
    tokio::task::spawn_blocking(move || {
        receipt_backend_api::auth::Identities::initialize(
            &database_root,
            std::env::var("RESET_ADMIN_PASSWORD").is_ok_and(|v| v.eq_ignore_ascii_case("true")),
        )
    })
    .await?
    .map_err(|e| std::io::Error::other(e.message))?;
    let state = State::new(config, root)?;
    let identities_root = state.identity_dir.clone();
    let users = tokio::task::spawn_blocking(move || {
        let s = receipt_backend_api::auth::Identities::open(&identities_root)?;
        s.purge_deleted()?;
        s.users(false)
    })
    .await?
    .map_err(|e| std::io::Error::other(e.message))?;
    for user in users {
        state.for_user(&user).await;
    }
    let listener = tokio::net::TcpListener::bind(address).await?;
    let (stop, rx) = watch::channel(false);
    let queue_state = state.clone();
    let mut queue_stop = rx.clone();
    let queue = tokio::spawn(async move {
        loop {
            tokio::select! {
                _=queue_stop.changed()=>break,
                _=tokio::time::sleep(Duration::from_secs(1))=>{receipt_backend_api::jobs::wake(queue_state.clone());for state in queue_state.users.lock().await.values(){receipt_backend_api::jobs::wake(state.clone());}},
            }
        }
    });
    let mut server = tokio::spawn(async move {
        let mut rx = rx;
        axum::serve(
            listener,
            application(state).into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .with_graceful_shutdown(async move {
            if !*rx.borrow() {
                let _ = rx.changed().await;
            }
        })
        .await
    });
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut server_done = false;
    let result: Result<(), Box<dyn std::error::Error + Send + Sync>> = tokio::select! {
        r=&mut server=>{server_done=true;match r { Ok(result)=>result.map_err(Into::into),Err(e)=>Err(e.into()) }},
        _=tokio::signal::ctrl_c()=>Ok(()),
        _=term.recv()=>Ok(()),
    };
    let _ = stop.send(true);
    queue.abort();
    if !server_done
        && tokio::time::timeout(Duration::from_secs(5), &mut server)
            .await
            .is_err()
    {
        server.abort();
    }
    result
}

fn optional_env(name: &str) -> Result<Option<String>, env::VarError> {
    match env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(env::VarError::NotPresent) => Ok(None),
        Err(error) => Err(error),
    }
}
