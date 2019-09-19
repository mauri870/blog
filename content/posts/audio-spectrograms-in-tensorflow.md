---
title: "Audio Spectrograms in Tensorflow"
date: 2018-05-24T00:05:00-03:00
tags: [
  "AI",
  "Tensorflow",
  "Sound Processing"
]
draft: false
---

A Spectrogram is a picture of sound. A common approach for audio classification tasks is to use spectrograms as input and simply treat the audio as an image. After several tries I finally got an optimized way to integrate the spectrogram generation pipeline into the tensorflow computational graph.

<!--more-->

---

We have a model for audio classification here at [FluxoTi](http://fluxoti.com) running in production about 100 thousand times a day for about one and a half year now. As we started researching about audio classification, we see that several people have achieved good results using [Convolutional Neural Networks](http://cs231n.github.io/convolutional-networks) applied to audio spectrograms. Our only problem was how to generate those spectrograms prior to feed then to the model 🤔.

## 1. The naive approach

In the first release of the project we have basically two applications: the tfrecords / train / eval tensorflow pipeline written in python and the production api written in Go.

Yes, we do serve the tensorflow exported model from Go, using CGO... **What a mistake.**

I mean, using Go was not a mistake, it's an incredible language and I love it. But serving the tensorflow model from Go (using the tensorflow CGO wrapper) use a LOT of ram after some weeks, reaching about 1GB each instance... Probably was a sort of memory leak, I tried to debug it but CGO is always on the way...

To generate the spectrogram in this first release we decided to use sox, it's a common command line utility for audio conversion and manipulation. Basically what we did was get the audio in the API and then save on disk, run the sox on the received sample, saving the generated spectrogram and then load the image bytes into a Tensorflow Tensor that we feed into the model.

Something like this:

```bash
sox audio.gsm -n spectrogram -x 128 -y 128 -A -z 50 -Z -20 -r -o spectrogram.png
```

However tests in production showed that we are hitting storage too hard. Storing and reading from disk about 2 or 3 times per request was pretty bad, so we cut out storage usage by using [pipes](http://www.linfo.org/pipes.html) everywhere:

```bash
 # In Go we fill the sox stdin with a buffer containing the gsm audio bytes
 # readed directly from request.
 sox -t gsm - -n spectrogram -x 128 -y 128 -A -z 50 -Z -20 -r -o -
 # PNG encoded image is contained in stdout buffer.
```

> We also found a known [sox bug](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=823417) with input/output pipes on Debian, which we solve compiling from source.

## 2. Improving the spectrogram generation

A couple of months ago I begin to refactor the project to use [Tensorflow Serving](https://www.tensorflow.org/serving/). The api was also lightweight now, it talks Protobuf through gRPC to the serving service and we don't have more memory leaks to worry about 😅. Each serving pod uses around 50MB of ram and the api 20MB. We keep the same sox approach as described above.

But sox isn't perfect... Segfaults happen randomly and the api cpu usage is higher bacause of the encoding / decoding operations.

Reading about the tensorflow contrib package I found some interesting ops, including a `audio_spectrogram`. With some work I replaced the entire sox pipeline by using the tensorflow computations, the api no longer deal with the preprocessing stuff. The only downside is that the ffmpeg ops don't support gsm, however it's ok for us to use wav instead.

Here's the source code for a program to test the spectrogram generation in  tensorflow 1.14:

```python
import tensorflow as tf
# FIXME: audio_ops.decode_wav is deprecated, use tensorflow_io.IOTensor.from_audio
from tensorflow.contrib.framework.python.ops import audio_ops

# Enable eager execution for a more interactive frontend.
# If using the default graph mode, you'll probably need to run in a session.
tf.enable_eager_execution()

@tf.function
def audio_to_spectrogram(
        audio_contents,
        width,
        height,
        channels=1,
        window_size=1024,
        stride=64,
        brightness=100.):
    """Decode and build a spectrogram using a wav string tensor.

    Args:
      audio_contents: String tensor of the wav audio contents.
      width: Spectrogram width.
      height: Spectrogram height.
      channels: Audio channel count.
      window_size: Size of the spectrogram window.
      stride: Size of the spectrogram stride.
      brightness: Brightness of the spectrogram.

    Returns:
      3-D encoded PNG Tensor with the spectrogram contents.
    """
	# Decode the wav mono into a 2D tensor with time in dimension 0
	# and channel along dimension 1
        waveform = audio_ops.decode_wav(
        	audio_contents, desired_channels=channels)
	
	# Compute the spectrogram
	# FIXME: Seems like this is deprecated in tensorflow 2.0 and
	# the operation only works on CPU. Change this to tf.signal.stft 
	# and  friends to take advantage of GPU kernels.
        spectrogram = audio_ops.audio_spectrogram(
        	waveform.audio,
        	window_size=window_size,
        	stride=stride)

	# Adjust brightness
        brightness = tf.constant(brightness)

	# Normalize pixels
        mul = tf.multiply(spectrogram, brightness)
        min_const = tf.constant(255.)
        minimum = tf.minimum(mul, min_const)

	# Expand dims so we get the proper shape
        expand_dims = tf.expand_dims(minimum, -1)

	# Resize the spectrogram to input size of the model
        resize = tf.image.resize(expand_dims, [width, height])

	# Remove the trailing dimension
        squeeze = tf.squeeze(resize, 0)

	# Tensorflow spectrogram has time along y axis and frequencies along x axis
	# so we fix that
        flip_left_right = tf.image.flip_left_right(squeeze)
        transposed = tf.image.transpose(flip_left_right)

	# Cast to uint8 and encode as png
        cast = tf.cast(transposed, tf.uint8)

	# Encode tensor as a png image
        return tf.image.encode_png(cast)

if __name__ == '__main__':
	input_file = tf.constant('input.wav')
	output_file = tf.constant('spectrogram.png')

	# Generage the spectrogram
	audio = tf.io.read_file(input_file)
	image = audio_to_spectrogram(audio, 224, 224)

	# Write the png encoded image to a file
	tf.io.write(output_file, image)
```

And it's pretty fast too, we reach about **30 to 50 milliseconds** including the preprocessing stuff and the model inference, that's pretty cool.

See you again next time 😄.
