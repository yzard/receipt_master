use receipt_backend_api::{State, application, config::Config};
use std::{env, time::Duration};
use tokio::sync::watch;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 || !matches!(args[1].as_str(), "--config" | "-c") {
        return Err("Usage: receipt-backend-api --config PATH".into());
    }
    let config = Config::parse(&tokio::fs::read_to_string(&args[2]).await?)?;
    let key = tokio::fs::read_to_string(&config.api_key_file).await?;
    let address = (config.host, config.port);
    let root = config.data_dir.clone();
    tokio::task::spawn_blocking(move || receipt_backend_api::db::Store::initialize(&root))
        .await?
        .map_err(|e| std::io::Error::other(e.message))?;
    let state = State::new(config, &key)?;
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
