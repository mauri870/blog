---
title: "Writing an Asterisk PBX module in Rust and C"
date: 2019-05-03T13:00:00-03:00
tags: [
  "Rust",
  "Asterisk",
  "C"
]
---

Asterisk modules are commonly written in C, but what about writing an Asterisk module in Rust? Let's find out.

<!--more-->

---

As I've already explained in an [older post](/blog/posts/audio-spectrograms-in-tensorflow), we have a Deep Learning microservice responsible for [Answering Machine Detection(AMD)](https://en.wikipedia.org/wiki/Auto_dialer#Answering_machine_detection). The problem is how to integrate this external service and make it accessible whitin an Asterisk dialplan.

## 1. AGI to the rescue

Our first attempt was to invoke a program acting as a client for the external service. Using the AGI application we're able to spawn our client within the dialplan, which is just a golang program.  

The client just sends a HTTP request to the AMD service with the initial recorded audio of the outbound call and some metadata and receives back a json response containing the prediction results. The relevant dialplan configuration looks like this:

```
; ommitted
same =>		n,Set(recording_amd=/var/spool/asterisk/monitor/${EXTEN}-${UNIQUEID}_amd-in) ; Set a variable containing the recording path
 same =>	n,Wait(0.3)
 same =>	n,MixMonitor(${recording_amd}.gsm) ; Start recording the call
 same =>	n,Playback(silence/2) ; Play 2s silence
 same =>	n,StopMixMonitor() ; Stop the recording
 same =>	n,AGI(amd-client,${recording_amd}.gsm) ; Invoke our client
 same =>	n,NoOp(${amd_result}) ; Does nothing. The variable amd_result contains the prediction result.
; omitted
```

This works well, but since the migration of our architecture to Kubernetes (also described [in this post](/blog/posts/gsutil-leak)) we started to face some problems, mainly involving [OOM](https://en.wikipedia.org/wiki/Out_of_memory) scenarios in our Kubernetes nodes. After much research and debug we find out that when the OOM errors occurs the pods have a lot of zombie processes of the amd-client. Since we can't found the root cause and I was already thinking of writing a native module, we decide to go ahead and give Rust a try.

## 2. Rust FFI

The problem of adopting the Rust language for this project is that Rust doesn't have a stabilized ABI and does not support [CPP](https://en.wikipedia.org/wiki/C_preprocessor) stuff, like macros and define. Then we have no choice but to write some C code to glue things together along with a library in Rust that export(`#[no_mangle]`) the functions and structs(`#[repr(C)]`) needed as a shared or static lib.

The following resources helped me a lot:

- [Rust FFI Omnibus](http://jakegoulding.com/rust-ffi-omnibus)
- [Rust Nomicon](https://doc.rust-lang.org/beta/nomicon/ffi.html)

For example our prediction struct looks like this:

```rust
/// A struct that wraps the code and confidence for a prediction
#[repr(C)]
pub struct AmdPrediction {
    code: u32,       // The integer prediction code
    confidence: f32, // The confidence of the prediction
    // ...
}
```

As you can see, we use `repr(C)` to allow this struct to be called from C code. We also have a function to lookup the string label for a given prediction code:

```rust
/// Retrieve the label corresponding to an amd status code
#[no_mangle]
pub extern "C" fn amd_label_name(code: u32) -> *const c_char {
    let label: &[u8] = match code {
        AMD_STATUS_MACHINE => b"machine\0",
        AMD_STATUS_HUMAN => b"human\0",
        AMD_STATUS_SILENCE => b"silence\0",
        AMD_STATUS_ERROR => b"error\0",
        _ => b"unknown\0",
    };
    label.as_ptr() as *const c_char
}
```

An interesting fact is that Rust do not accept null values, but it can in fact create a null raw pointer using `std::ptr::null`:

```rust
/// Performs the inference for a given file and return a pointer to an `AmdPrediction`
#[no_mangle]
pub extern "C" fn amd_inference(file: *const c_char) -> *mut AmdPrediction {
    if file.is_null() {
        return std::ptr::null_mut();
    }

    let file = unsafe { CStr::from_ptr(file).to_str() }.unwrap();

    let prediction = match amd_do_inference(file) {
        Ok(pred) => pred,
        Err(e) => {
            error::set_last_error(e);
            return std::ptr::null_mut();
        }
    };

    Box::into_raw(Box::new(prediction))
}
```

The memory that is allocated by Rust, should be freed by Rust. So we also need to export a function to free up the allocated memory.

```rust
/// Free an `AmdPrediction` pointer
#[no_mangle]
pub extern "C" fn amd_prediction_free(ptr: *mut AmdPrediction) {
    if ptr.is_null() {
        return;
    }

    unsafe {
        Box::from_raw(ptr);
    }
}
```

By creating a Box using a raw pointer, we bring it back to the rust land so it'll be freed when they reach the end of the scope at the end of the unsafe block.

Another interesting topic is how to handle errors in a rust library. Since we need to expose those errors to C, a common approach is to use a thread local variable to keep track of the last error that occured in the library, exposing a function to retrieve the error, something like this:

```rust
use std::cell::RefCell;
use std::ffi::CString;
use std::error::Error as StdError;
use libc::c_char;

thread_local! {
    /// An `errno`-like thread-local variable which keeps track of the most
    /// recent error to occur in the library.
    static LAST_ERROR: RefCell<Option<LastError>> = RefCell::new(None);
}

/// Keeps track of the latest error
#[derive(Debug)]
struct LastError {
    error: Box<StdError>,
    c_string: CString,
}

/// A C friendly struct to hold the latest error message
#[derive(Debug, PartialEq)]
#[repr(C)]
pub struct MyLibError {
    msg: *const c_char,
}

// A default error for when no error has actually occurred
impl Default for MyLibError {
    fn default() -> MyLibError {
        MyLibError {
            msg: std::ptr::null(),
        }
    }
}

/// Change LAST_ERROR with the last error that occured in the library
pub (crate) fn set_last_error(err: Box<StdError>) {
    LAST_ERROR.with(|l| {
        let c_string = CString::new(err.to_string()).unwrap_or_default();

        let new_error = LastError {
            error: err,
            c_string,
        };

        *l.borrow_mut() = Some(new_error);
    });
}

/// Retrieve the most recent error
#[no_mangle]
pub unsafe extern "C" fn mylib_last_error() -> AmdError {
    LAST_ERROR.with(|l| match l.borrow().as_ref() {
        Some(err) => MyLibError {
            msg: err.c_string.as_ptr(),
        },
        None => MyLibError::default(),
    })
}

/// Clear the last error
#[no_mangle]
pub extern "C" fn mylib_clear_last_error() {
    LAST_ERROR.with(|l| l.borrow_mut().take());
}
```

This makes it easy to set errors (by using the `set_last_error`) and to retrieve then in C, using the `mylib_last_error` function. The memory of the error is also freed when another error occurs.

In order to automate the library header generation we use cbindgen by invoking it in our build.rs file so Cargo can generate it  when building our library. We still need make tho in order to compile the asterisk module since the rust part is just the library. Our project was based on [this module](https://github.com/zaf/Asterisk-eSpeak) as an initial template.

## 3. Loading and testing the module

In order to load the module in asterisk we need to put the rust library shared object into the `$LD_LIBRARY_PATH`, run `ldconfig` and put the path to the shared object file of the module in the asterisk `modules.conf` file.

Then we're ready to load the module:

```bash
root@e3b75b6f6141:/# asterisk -x "module load app_3cplus_amd"
Loaded app_3cplus_amd
root@e3b75b6f6141:/# asterisk -x "module show like app_3cplus_amd"
Module                         Description                              Use Count  Status      Support Level
app_3cplus_amd.so              AMD interface for the 3cplus/amd project 0          Running           unknown
1 modules loaded
```

And the dialplan config:

```
; ommitted
same =>		n,Set(recording_amd=/var/spool/asterisk/monitor/${EXTEN}-${UNIQUEID}_amd-in) ; Set a variable containing the recording path
 same =>	n,Wait(0.3)
 same =>	n,MixMonitor(${recording_amd}.gsm) ; Start recording the call
 same =>	n,Playback(silence/2) ; Play 2s silence
 same =>	n,StopMixMonitor() ; Stop the recording
 
 ; Easy peasy
 same =>	n,3cplusAMD(${recording_amd}.gsm) ; Invoke our native application
 
 same =>	n,NoOp(${amd_result}) ; Does nothing. The variable amd_result contains the prediction result.
; omitted
```

We're running this module in production for 2 weeks now. The OOM problems ceased, the resource usage is lower and we are pretty happy to put all together and this is the first project ever using Rust at our company and it won't be the last for sure.

That's it for now, see you again next time.
