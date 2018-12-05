---
title: "Asterisk leaking resources? No, it's gsutil :'("
date: 2018-12-05T10:00:00-03:00
tags: [
  "Asterisk",
  "Google Storage",
  "Golang",
  "Kubernetes",
  "GKE",
  "Optimization",
]
draft: false
---

This week we solved a resource leak in our asterisk images reserved for call handling. Here's the path we follow to mitigate the issue, which we find out to be related with the gsutil command line tool.

<!--more-->

---

We recently switched our infraestructure and applications to Google Kubernetes Engine, including our telephony stack.

One of the main problems of the migration were the storage volumes provided by GCP. In the old architecture, running Kubernetes on top of Rancher, we use a NFS server to provide storage volumes for our pods, mounted as ReadWriteMany. This works well for the asterisk call recordings because we mounted the same volume in all asterisk pods, since the NFS server handle the write calls. 

When we move to GKE, the volumes available are raw disks, and we can only mount those for writing in a single node. The solution we came across is to use Google Storage Buckets.

## 1. Uploading files with gsutil in production: a big mistake

Btw I don't know why I thought this would be a good choice...

The initial idea was to code a simple tool to upload files to the bucket. Since I saw the Gsutil command line tool, it looked perfect for the job. 

We already have some routines to handle the call recordings in an asterisk stasis, basically audio conversion using [sox](http://sox.sourceforge.net/). The only changes we made was to install the Google Cloud SDK(already contains the gsutil tool) in the image, along with a valid service account with write storage permission in runtime.

This seems great and in fact it works well, until we saw the resource usage in production... The pods constantly went to an `Evicted` state, basically exausting the node resources until the scheduler decides to remove the offending pod, which happens a lot, basically after every half hour. Since the instances keep the call sessions, when each pod exits the calls are gone for the clients :'(.

Here's the load of the running pods. You can see that each one is using about 3vCPU. The ram usage seems lower, but the majority of the evicted pods are due to nearly OOM failures.

```bash
$ kubectl top pods | grep asterisk-calls
mask-asterisk-calls-655c957dcb-5d8vm             3924m        305Mi
mask-asterisk-calls-655c957dcb-cn5ss             3194m        192Mi
mask-asterisk-calls-655c957dcb-4cdq2             3256m        337Mi
mask-asterisk-calls-655c957dcb-gskj6             3717m        619Mi
mask-asterisk-calls-655c957dcb-gwsdx             3936m        715Mi
mask-asterisk-calls-655c957dcb-n6gt7             3890m        256Mi
mask-asterisk-calls-655c957dcb-pkgql             3950m        239Mi
```

Initially I though that was an asterisk leak of some sort, then after exec(ing) in some of the pods to inspect what's happening we find a lot of python processes still running, waiting for an event to be completed, all of these created by gsutil. Then we find out that the resource leak was indeed related to the gsutil tool and not asterisk. 

## 2. Getting rid of gsutil

We already have a golang microservice that's responsible to serve the call recordings from the bucket, so I suggested to move the "uploading to bucket" role to it, removing the need of gsutil and the cloud sdk.

Using the `cloud.google.com/go/storage` package, it acts as a front layer for the storage, providing a local filesystem (for local testing) and a cloud storage implementation (for production).

We use this simple script to upload the recordings using curl:

```bash
#!/bin/bash
RECORDINGS_DIR=/var/spool/asterisk/monitor/
if [ "$#" -ne 1 ]
then
  echo "Usage: upload-recording.sh ${RECORDINGS_DIR}path/to/file.gsm"
  exit 1
fi

RECORDING_PATH="$1"
RECORDING_RELATIVE=${RECORDING_PATH#"${RECORDINGS_DIR}"}
if [ -e "$RECORDING_PATH" ]; then
    curl -XPOST \
      -F "filename=${RECORDING_RELATIVE}" \
      -F "file=@${RECORDING_PATH}" ${RECORDINGS_SERVER}/create && \
    rm "${RECORDING_PATH}"
fi
```

The recordings microservice stands behind a service (internal lb in kubernetes) and with graceful shutdown in the http server, it works pretty well with no downtime.

Here's the most critical part of handler function that saves the file, as you can see we use `io.Copy` to stream the file contents directly to the underlying storage implementation. The `io.Reader` and `io.Writer` are key interfaces in Go and used pretty much everywhere in the stdlib, from http to crypto packages:

```go
func createHandler(sto storage.Storage) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		err := r.ParseMultipartForm(32 << 20)
		if err != nil {
			log.Errorln(err)
			rw.WriteHeader(http.StatusInternalServerError)
			return
		}

		filename := r.FormValue("filename")
		if filename == "" {
			log.Errorln("Filename cannot be empty!")
			rw.WriteHeader(http.StatusInternalServerError)
			return
		}

		file, _, err := r.FormFile("file")
		if err != nil {
			log.Errorln(err)
			rw.WriteHeader(http.StatusInternalServerError)
			return
		}
		defer file.Close()

		writer, err := sto.Put(filename)
		if _, err = io.Copy(writer, file); err != nil {
			log.Errorf("Failed to copy file contents from request: %s\n", err)
			return
		}

		if err = writer.Close(); err != nil {
			log.Errorf("Error while closing writer: %s\n", err)
			rw.WriteHeader(http.StatusInternalServerError)
			return
		}

		log.Infof("Saved file %s\n", filename)
	})
}
```

Here's a canary deploy we made to test out the changes, you can see how big was the resource leak generated by gsutil:

```bash
$ kubectl top pods | grep asterisk-calls
mask-asterisk-calls-655c957dcb-5d8vm             3924m        305Mi
mask-asterisk-calls-655c957dcb-cn5ss             3194m        192Mi
mask-asterisk-calls-655c957dcb-gqlvd             347m         92Mi <- canary deploy here
mask-asterisk-calls-655c957dcb-gskj6             3717m        619Mi
mask-asterisk-calls-655c957dcb-gwsdx             3936m        715Mi
mask-asterisk-calls-655c957dcb-n6gt7             3890m        256Mi
mask-asterisk-calls-655c957dcb-pkgql             3950m        239Mi
```

> It's about 8x less resource usage!

And here is the full production rollout:

```bash
$ kubectl top pods | grep 'asterisk-calls\|recordings-server'
mask-asterisk-calls-56c64d497f-2spsf             230m         72Mi
mask-asterisk-calls-56c64d497f-9fh6f             215m         73Mi
mask-asterisk-calls-56c64d497f-fhzxg             340m         75Mi
mask-asterisk-calls-56c64d497f-hb764             374m         80Mi
mask-asterisk-calls-56c64d497f-pdvg5             309m         87Mi
mask-asterisk-calls-56c64d497f-r5gxw             378m         94Mi
mask-asterisk-calls-56c64d497f-z96vm             307m         103Mi
mask-recordings-server-5c74d6b859-jvbzr          19m          69Mi
mask-recordings-server-5c74d6b859-jznsm          20m          69Mi
mask-recordings-server-5c74d6b859-t5bfc          19m          76Mi
mask-recordings-server-5c74d6b859-wbqxs          21m          69Mi
```


The effect was so big that our cluster size decreased from 8 to 4 nodes, that's insane. 🤯
