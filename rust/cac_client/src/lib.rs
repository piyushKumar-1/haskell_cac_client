mod eval;
mod utils;
mod superposition_client;
mod types;

#[macro_use]
extern crate lazy_static;

use actix_web::{
    rt::{time::interval},
    web::Data
};
use chrono::{DateTime, Utc};
use derive_more::{Deref, DerefMut};
use reqwest::{RequestBuilder, Response, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{
    collections::HashMap,
    convert::identity,
    sync::{Arc, RwLock},
    time::{Duration, UNIX_EPOCH, SystemTime},
};
use tokio::{runtime::Runtime, task};
use utils::core::MapError;
use tokio::sync::oneshot;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_uint, c_ulonglong, c_int};

use superposition_client as sp;

type FutureId = u64;

type SyncMap<K, V> = RwLock<HashMap<K, V>>;
// let local_set = LocalSet::new();

lazy_static! {
    // Map for feedback channels. Once result is computed, it is stored at `RESULTS`
    static ref STATUSES: SyncMap<FutureId, oneshot::Receiver<&'static str>> = SyncMap::default();
    // Cache storage for results
    static ref RESULTS: SyncMap<FutureId, &'static str> = SyncMap::default();
}

fn convert_c_str_to_rust_str(c_str: *const c_char) -> String {
    unsafe {
        CStr::from_ptr(c_str).to_string_lossy().into_owned()
    }
}

fn convert_c_array_to_vec(c_array: *const *const c_char, count: c_uint) -> Vec<String> {
    (0..count).map(|i| {
        let c_str = unsafe { *c_array.offset(i as isize) };
        convert_c_str_to_rust_str(c_str)
    }).collect()
}

fn convert_to_rust_duration(secs: c_ulonglong, nanos: c_uint) -> std::time::Duration {
    std::time::Duration::new(secs, nanos)
}

#[no_mangle]
pub extern "C" fn init_cac_clients(hostname: *const c_char, polling_interval_secs : c_ulonglong, tenants : *const *const c_char, tenants_count: c_uint) -> c_int {
    let (tx, rx) = oneshot::channel();
    let cac_hostname = convert_c_str_to_rust_str(hostname);
    let polling_interval = convert_to_rust_duration(polling_interval_secs, 0);
    let cac_tenants = convert_c_array_to_vec(tenants, tenants_count);

    // Spawn an async task
    let local = task::LocalSet::new();
    local.block_on(&Runtime::new().unwrap(), async move {

        for tenant in cac_tenants {
            match CLIENT_FACTORY
                .create_client(
                    tenant.to_string(),
                    polling_interval,
                    cac_hostname.to_string(),
                )
                .await {
                    Ok(x) => {
                        println!("CAC Client created successfully for tenant {:?} and value:  {:?}", tenant, x);
                    },
                    Err(err) => {
                        // update_last_error(err);
                        println!("Failed to create cac client for tenant {:?}: {:?}", tenant, err);
                        return 1;
                    }
                };
        }
        tx.send("CLIENTS_CREATED").unwrap();
        return 0;
    })
}

#[no_mangle]
pub extern "C" fn init_superposition_clients(hostname: *const c_char, polling_frequency : c_ulonglong, tenants : *const *const c_char, tenants_count: c_uint) -> c_int {
    let (tx, rx) = oneshot::channel();
    let hostname = convert_c_str_to_rust_str(hostname);
    let poll_frequency = polling_frequency as u64;
    let cac_tenants = convert_c_array_to_vec(tenants, tenants_count);
    let local = task::LocalSet::new();
    local.block_on(&Runtime::new().unwrap(), async move {
        for tenant in cac_tenants {
                match sp::CLIENT_FACTORY
                    .create_client(tenant.to_string(), poll_frequency, hostname.to_string(), true)
                    .await {
                        Ok(x) => {
                            println!("Superposition Client created successfully for tenant {:?} and val: {:?}", tenant, x);
                        },
                        Err(err) => {
                            // update_last_error(err);
                            println!("Superposition Client Failed to create client for tenant {:?} with err: {:?}", tenant, err);
                            return 1;
                        }
                }      
        }
        tx.send("CLIENTS_CREATED").unwrap();
        return 0;
    })
}

fn get_sp_client(tenant: String) -> Arc<sp::Client> {
    let rt = Runtime::new().unwrap();
    rt.block_on(async {
        match sp::CLIENT_FACTORY
        .get_client(tenant.clone())
        .await
        .map_err(|e| {
            log::error!("{}: {}", tenant, e);
            format!("{}: Failed to get superposition client", tenant)
            
        }){
            Ok(x) => x,
            Err(e) => {
                println!("Failed to get superposition client: {:?}", e);
                println!("Retrying in 5 seconds");
                tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                get_sp_client(tenant)
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn run_polling_updates(c_tenant: *const c_char) {
    let rt = Runtime::new().unwrap();
    let tenant = convert_c_str_to_rust_str(c_tenant);
    let sp_client = get_sp_client(tenant.clone());
    rt.block_on(async {
        sp_client.run_polling_updates().await;
    });
            // let sp_client = match sp::CLIENT_FACTORY
            // .get_client(tenant.clone())
            // .await
            // .map_err(|e| {
            //     log::error!("{}: {}", tenant, e);
            //     format!("{}: Failed to get superposition client", tenant)
            // })
            // {
            //     Ok(x) => x,
            //     Err(e) => {
            //         println!("Failed to get superposition client: {:?}", e);
            //         return;
            //     }
            // };
}

#[no_mangle]
pub extern "C" fn start_polling_updates(c_tenant: *const c_char) {
    let rt = Runtime::new().unwrap();
    let tenant = convert_c_str_to_rust_str(c_tenant);
    rt.block_on(async {
        
        let client = match CLIENT_FACTORY
            .get_client(tenant.clone())
            .map_err(|e| {
                log::error!("{}: {}", tenant, e);
                format!("{}: Failed to get cac client", tenant)
            })
            {
                Ok(x) => x,
                Err(e) => {
                    println!("Failed to get cac client: {:?}", e);
                    return;
                }
            };
        client.start_polling_update().await;
    });
}

fn serialize_map_to_json(map: &Map<String, Value>) -> Result<CString, serde_json::Error> {
    serde_json::to_string(map)
        .map(|json_str| CString::new(json_str).expect("CString::new failed"))
}

fn serialize_vec_to_json(vec: &Vec<String>) -> Result<CString, serde_json::Error> {
    serde_json::to_string(vec)
        .map(|json_str| CString::new(json_str).expect("CString::new failed"))
}

#[no_mangle]
pub extern "C" fn eval_ctx(c_tenant: *const c_char, ctx_json: *const c_char) -> *const c_char {
    let tenant = convert_c_str_to_rust_str(c_tenant);
    let cac_client = match CLIENT_FACTORY.get_client(tenant.clone()).map_err(|e| {
        log::error!("{}: {}", tenant, e);
        format!("{}: Failed to get cac client", tenant)
    })
    {
        Ok(x) => x,
        Err(e) => {
            println!("Failed to get cac client: {:?}", e);
            return CString::new("Failed to get cac client").expect("Failed to create CString").into_raw();
        }
    };
    let ctx_str = unsafe { CStr::from_ptr(ctx_json).to_str().unwrap() };
    let ctx_obj: Map<String, Value> = serde_json::from_str(ctx_str).unwrap();
    let overrides = match cac_client.eval(ctx_obj) {
        Ok(x) => x,
        Err(e) => {
            println!("Failed to evaluate the context: {:?}", e);
            return CString::new("Failed to evaluate the context").expect("Failed to create CString").into_raw();
        }
    };
    let searialized_string = serialize_map_to_json(&overrides).expect("JSON serialization failed");
    let c_string = CString::new(searialized_string).expect("Failed to create CString");
    return c_string.into_raw();

}

fn  c_char_to_json(ptr: *const c_char) -> Result<Value, String> {
    // Ensure the pointer is not null
    assert!(!ptr.is_null());

    // Convert to CStr and then to a Rust String
    let c_str = unsafe { CStr::from_ptr(ptr) };
    let result = c_str.to_str().map_err(|e| e.to_string());

    match result {
        Ok(str_slice) => {
            // Now `str_slice` is an &str
            serde_json::from_str(str_slice).map_err(|e| e.to_string())
        }
        Err(e) => Err(e.to_string()), // Convert the error to YourErrorType
    }
    
}

#[no_mangle]
pub extern "C" fn get_variants(c_tenant: *const c_char, context: *const c_char, toss: c_int) -> *const c_char {
    let ctx_str = c_char_to_json(context).expect("Failed to parse the context");
    let toss_value = toss as i8;
    let rt = Runtime::new().unwrap();
    let tenant = convert_c_str_to_rust_str(c_tenant);
    let sp_client = match rt.block_on (async{sp::CLIENT_FACTORY
        .get_client(tenant.clone())
        .await
        .map_err(|e| {
            log::error!("{}: {}", tenant, e);
            format!("{}: Failed to get superposition client", tenant)
        })})
        {
            Ok(x) => x,
            Err(e) => {
                println!("Failed to get superposition client: {:?}", e);
                return CString::new("Failed to get superposition client").expect("Failed to create CString").into_raw();
            }
        };
    let variant_ids = rt.block_on(async{sp_client.get_applicable_variant(&ctx_str, toss_value).await});
    let searialized_string = serialize_vec_to_json(&variant_ids).expect("JSON serialization failed");
    let c_string = CString::new(searialized_string).expect("Failed to create CString");
    return c_string.into_raw();
}

#[no_mangle]
pub extern "C" fn is_experiments_running(c_tenant: *const c_char) -> c_int {
    let rt = Runtime::new().unwrap();
    let tenant = convert_c_str_to_rust_str(c_tenant);
    let sp_client = match rt.block_on (async{sp::CLIENT_FACTORY
        .get_client(tenant.clone())
        .await
        .map_err(|e| {
            log::error!("{}: {}", tenant, e);
            format!("{}: Failed to get superposition client", tenant)
        })})
        {
            Ok(x) => x,
            Err(e) => {
                println!("Failed to get superposition client: {:?}", e);
                return 2;
            }
        };
    let running_experiments = rt.block_on(async{sp_client.get_running_experiments().await});
    if running_experiments.len() > 0 {
        return 1;
    }
    return 0;
}

#[no_mangle]
pub extern "C" fn eval_experiment(c_tenant: *const c_char, context: *const c_char, toss: c_int) -> *const c_char {
    let ctx_str = c_char_to_json(context).expect("Failed to parse the context");
    let toss_value = toss as i8;
    let rt = Runtime::new().unwrap();
    let tenant = convert_c_str_to_rust_str(c_tenant);
    let sp_client = rt.block_on (async{sp::CLIENT_FACTORY
        .get_client(tenant.clone())
        .await
        .map_err(|e| {
            log::error!("{}: {}", tenant, e);
            format!("{}: Failed to get superposition client", tenant)
        })});
    match sp_client {
        Ok(x) => {
            let variant_ids = rt.block_on(async{x.get_applicable_variant(&ctx_str, toss_value).await});
            let cac_client = match CLIENT_FACTORY.get_client(tenant.clone()).map_err(|e| {
                log::error!("{}: {}", tenant, e);
                format!("{}: Failed to get cac client", tenant)
            })
            {
                Ok(x) => x,
                Err(e) => {
                    println!("Failed to get cac client: {:?}", e);
                    return CString::new("Failed to get cac client").expect("Failed to create CString").into_raw();
                }
            };
            let mut ctx: serde_json::Map<String, Value> = serde_json::from_value(json!(ctx_str)).expect("Failed to convert to a map");
            ctx.insert(String::from("variantIds"), json!(variant_ids));
            let overrides = cac_client.eval(ctx).expect("Failed to evaluate the context");
            let searialized_string = serialize_map_to_json(&overrides).expect("JSON serialization failed");
            let c_string = CString::new(searialized_string).expect("Failed to create CString");
            return c_string.into_raw();
        },
        Err(e) => {
            println!("Failed to get superposition client: {:?}", e);
            return CString::new("Failed to get superposition client").expect("Failed to create CString").into_raw();
        }
    }
}

#[no_mangle]
pub extern "C" fn free_json_data(s: *mut c_char) {
    unsafe {
        if s.is_null() { return }
        drop(CString::from_raw(s))
    }
}

#[no_mangle]
pub extern "C" fn create_client_from_config(c_tenant: *const c_char, polling_interval_secs: c_ulonglong, config: *const c_char, hostname: *const c_char) -> c_int {
    let tenant = convert_c_str_to_rust_str(c_tenant);
    let polling_interval = convert_to_rust_duration(polling_interval_secs, 0);
    let config_str = c_char_to_json(config);
    match config_str {
        Ok(x) => {
            let hostname_str = convert_c_str_to_rust_str(hostname);
            let rt = Runtime::new().unwrap();
            rt.block_on(async {
                match CLIENT_FACTORY
                    .create_client_with_config(
                        tenant.to_string(),
                        polling_interval,
                        x,
                        hostname_str.to_string()
                    ) {
                        Ok(x) => {
                            println!("CAC Client created successfully ");
                            match sp::CLIENT_FACTORY
                                .create_client_with_config(
                                    tenant.to_string(),
                                    polling_interval.as_secs(),
                                    hostname_str.to_string(),
                                    false,
                                )
                                .await {
                                    Ok(x) => {
                                        println!("Superposition Client created successfully ");
                                    },
                                    Err(err) => {
                                        // update_last_error(err);
                                        println!("Failed to create superposition client: {:?}", err);
                                        return 1;
                                    }
                                };
                        },
                        Err(err) => {
                            // update_last_error(err);
                            println!("Failed to create cac client: {:?}", err);
                            return 1;
                        }
                    };
                return 0;
            })
        },
        Err(e) => {
            println!("Failed to parse the config: {} {:?} str", e, config);
            return 1;
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Context {
    pub condition: Value,
    pub override_with_keys: [String; 1],
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Config {
    contexts: Vec<Context>,
    overrides: Map<String, Value>,
    default_configs: Map<String, Value>,
}

#[derive(Clone)]
#[derive(Debug)]
pub struct Client {
    tenant: String,
    reqw: Data<reqwest::RequestBuilder>,
    polling_interval: Duration,
    last_modified: Data<RwLock<DateTime<Utc>>>,
    config: Data<RwLock<Config>>,
    enable_polling: Data<RwLock<bool>>,
}

fn clone_reqw(reqw: &RequestBuilder) -> Result<RequestBuilder, String> {
    reqw.try_clone()
        .ok_or_else(|| "Unable to clone reqw".to_string())
}

fn get_last_modified(resp: &Response) -> Option<DateTime<Utc>> {
    resp.headers().get("last-modified").and_then(|header_val| {
        let header_str = header_val.to_str().ok()?;
        DateTime::parse_from_rfc2822(header_str)
            .map(|datetime| datetime.with_timezone(&Utc))
            .map_err(|e| {
                log::error!("Failed to parse date: {e}");
            })
            .ok()
    })
}

impl Client {
    pub async fn new(
        tenant: String,
        polling_interval: Duration,
        hostname: String,
    ) -> Result<Self, String> {
        let reqw_client = reqwest::Client::builder().build().map_err_to_string()?;
        let cac_endpoint = format!("{hostname}/config");
        let reqw = reqw_client
            .get(cac_endpoint)
            .header("x-tenant", tenant.to_string());

        let reqwc = clone_reqw(&reqw)?;
        let resp = reqwc.send().await.map_err_to_string()?;
        let last_modified_at = get_last_modified(&resp);
        let config = resp.json::<Config>().await.map_err_to_string()?;

        let client = Client {
            tenant,
            reqw: Data::new(reqw),
            polling_interval,
            last_modified: Data::new(RwLock::new(
                last_modified_at.unwrap_or(DateTime::<Utc>::from(UNIX_EPOCH)),
            )),
            config: Data::new(RwLock::new(config)),
            enable_polling: Data::new(RwLock::new(true)),
        };
        // if update_config_periodically {
        //     client.clone().start_polling_update().await;
        // }
        Ok(client)
    }

    pub fn new_with_config(
        tenant: String,
        polling_interval: Duration,
        config: Value,
        hostname: String
    ) -> Self { 
        let new_config1 = serde_json::from_value(config).unwrap();
        let new_config2 = Data::new(RwLock::new(new_config1));
        let reqw_client = reqwest::Client::builder().build().expect("Failed to build reqwest client");
        let cac_endpoint = format!("{hostname}/config");
        let reqw = reqw_client
            .get(cac_endpoint)
            .header("x-tenant", tenant.to_string());
        Client {
            tenant,
            reqw: Data::new(reqw),
            polling_interval,
            last_modified: Data::new(RwLock::new(
                DateTime::<Utc>::from(UNIX_EPOCH)
            )),
            config : new_config2,
            enable_polling: Data::new(RwLock::new(false)),
        }
    }

    async fn fetch(&self) -> Result<reqwest::Response, String> {
        let last_modified = self.last_modified.read().map_err_to_string()?.to_rfc2822();
        let reqw = clone_reqw(&self.reqw)?.header("If-Modified-Since", last_modified);
        let resp = reqw.send().await.map_err_to_string()?;
        match resp.status() {
            StatusCode::NOT_MODIFIED => {
                return Err(String::from(format!(
                    "{} CAC: skipping update, remote not modified",
                    self.tenant
                )));
            }
            StatusCode::OK => log::info!(
                "{}",
                format!("{} CAC: new config received, updating", self.tenant)
            ),
            x => return Err(format!("{} CAC: fetch failed, status: {}", self.tenant, x)),
        };
        Ok(resp)
    }

    async fn update_cac(&self) -> Result<String, String> {
        let fetched_config = self.fetch().await?;
        let mut config = self.config.write().map_err_to_string()?;
        let mut last_modified = self.last_modified.write().map_err_to_string()?;
        let last_modified_at = get_last_modified(&fetched_config);
        *config = fetched_config.json::<Config>().await.map_err_to_string()?;
        if let Some(val) = last_modified_at {
            *last_modified = val;
        }
        Ok(format!("{}: CAC updated successfully", self.tenant))
    }

    pub async fn start_polling_update(self: Arc<Self>) {
        let mut interval = interval(self.polling_interval);
        let enable_poll = self.enable_polling.read().unwrap();
        let enable = *enable_poll;
        loop {
            match enable {
                true => {
                    interval.tick().await;
                    self.update_cac().await.unwrap_or_else(identity);
                }
                false => {
                    let _ = interval.tick().await;
                }
            }
            
        }
    }

    pub fn get_config(&self) -> Result<Config, String> {
        self.config.read().map(|c| c.clone()).map_err_to_string()
    }

    pub fn get_last_modified<E>(&'static self) -> Result<DateTime<Utc>, String> {
        self.last_modified.read().map(|t| *t).map_err_to_string()
    }

    pub fn eval(
        &self,
        query_data: Map<String, Value>,
    ) -> Result<Map<String, Value>, String> {
        let cac = self.config.read().map_err_to_string()?;
        eval::eval_cac(
            cac.default_configs.to_owned(),
            &cac.contexts,
            &cac.overrides,
            &query_data,
        )
    }
}

#[derive(Deref, DerefMut)]
pub struct ClientFactory(RwLock<HashMap<String, Arc<Client>>>);
impl ClientFactory {
    pub async fn create_client(
        &self,
        tenant: String,
        polling_interval: Duration,
        hostname: String,
    ) -> Result<Arc<Client>, String> {
        let mut factory = match self.write() {
            Ok(factory) => factory,
            Err(e) => {
                log::error!("CAC_CLIENT_FACTORY: failed to acquire write lock {}", e);
                return Err("CAC_CLIENT_FACTORY: Failed to create client".to_string());
            }
        };

        if let Some(client) = factory.get(&tenant) {
            return Ok(client.clone());
        }

        let client = Arc::new(
            Client::new(
                tenant.to_string(),
                polling_interval,
                hostname,
            )
            .await?,
        );
        factory.insert(tenant.to_string(), client.clone());
        return Ok(client.clone());
    }

    pub fn create_client_with_config(
        &self,
        tenant: String,
        polling_interval: Duration,
        config: Value,
        hostname: String
    ) -> Result<Arc<Client>, String> {
        let tenant_clone =  tenant.clone();
        let mut factory = match self.write() {
            Ok(factory) => factory,
            Err(e) => {
                log::error!("CAC_CLIENT_FACTORY: failed to acquire write lock {}", e);
                return Err("CAC_CLIENT_FACTORY: Failed to create client".to_string());
            }
        };


        let client = Arc::new(
            Client::new_with_config(
                tenant,
                polling_interval,
                config,
                hostname
            ));
        factory.insert(tenant_clone.to_string(), client.clone());
        Ok(client.clone())
    }

    pub fn get_client(&self, tenant: String) -> Result<Arc<Client>, String> {
        let factory = match self.read() {
            Ok(factory) => factory,
            Err(e) => {
                log::error!("CAC_CLIENT_FACTORY: failed to acquire read lock {}", e);
                return Err("CAC_CLIENT_FACTORY: Failed to acquire client.".to_string());
            }
        };

        match factory.get(&tenant) {
            Some(client) => Ok(client.clone()),
            None => Err("No such tenant found".to_string()),
        }
    }
}

use once_cell::sync::Lazy;
pub static CLIENT_FACTORY: Lazy<ClientFactory> =
    Lazy::new(|| ClientFactory(RwLock::new(HashMap::new())));

pub use eval::eval_cac;
