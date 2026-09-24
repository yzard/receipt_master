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
    let config = Config::parse(&tokio::fs::read_to_string(root.join("config.toml")).await?)?;
    let address = (config.general.host, config.general.port);
    let database_root = root.clone();
    tokio::task::spawn_blocking(move || receipt_backend_api::db::Store::initialize(&database_root))
        .await?
        .map_err(|e| std::io::Error::other(e.message))?;
    let state = State::new(config, root)?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    let (stop, rx) = watch::channel(false);
    let queue_state = state.clone();
    let mut queue_stop = rx.clone();
    let queue = tokio::spawn(async move {
        loop {
            tokio::select! {
                _=queue_stop.changed()=>break,
                _=tokio::time::sleep(Duration::from_secs(1))=>receipt_backend_api::jobs::wake(queue_state.clone()),
            }
        }
    });
    let mut server = tokio::spawn(async move {
        let mut rx = rx;
        axum::serve(listener, application(state))
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
