#!/bin/bash

# Apache 2.0
# This script builds CNN hybrid systems over the filterbank features. It is
# to be run after run.sh. Before running this, you should already build the 
# initial GMM model. This script requires a GPU, and  also the "pdnn" tool-
# kit to train the CNN. The input filterbank  features are  with  mean  and
# variance normalization. We are applying 2D convolution (time x frequency).
# You can easily switch to 1D convolution (only on frequency) by redefining
# the CNN architecture.

# For more informaiton regarding the recipes and results, visit our webiste
# http://www.cs.cmu.edu/~ymiao/kaldipdnn

working_dir=exp_deeplearn/spn
delete_pfile=false # whether to delete pfiles after CNN training
deeplearn_path=$HOME/experiments/bin/deeplearn
export LD_LIBRARY_PATH=/usr/local/cuda-5.5/lib64:$LD_LIBRARY_PATH   # libraries (CUDA, boost, protobuf)
gpu_mem_limit=3     # available GPU memory used for the dataset, in GB. Should be 1GB less than the total GPU memory

gmmdir=exp/tri3

# Specify the gpu device to be used
gpu=gpu

# Here are two critical variables. With the following default configuration,
# we input speech frames as 29x29 images into CNN. Convolution over the time
# axis is not intuitive. But in practice, this works well. If you change the
# values, then you have to change the CNN definition accordingly.
fbank_dim=29  # the dimension of fbanks on each frame
splice_opts="--left-context=14 --right-context=14"  # splice of fbank frames over time

cmd=run.pl
. cmd.sh
[ -f path.sh ] && . ./path.sh
. parse_options.sh || exit 1;

# At this point you may want to make sure the directory $working_dir is
# somewhere with a lot of space, preferably on the local GPU-containing machine.
if [ ! -d kaldi-deeplearn ]; then
  echo "Checking out kaldi-deeplearn code."
  git clone https://github.com/phvu/kaldi-deeplearn.git
fi

if [ ! -d steps_deeplearn ]; then
  echo "Checking out steps_deeplearn scripts."
  exit 1;
  git clone https://github.com/phvu/steps_deeplearn.git
fi

if ! nvidia-smi; then
  echo "The command nvidia-smi was not found: this probably means you don't have a GPU."
  exit 1;
fi

pythonCMD=python

mkdir -p $working_dir/log

! gmm-info $gmmdir/final.mdl >&/dev/null && \
   echo "Error getting GMM info from $gmmdir/final.mdl" && exit 1;

num_pdfs=`gmm-info $gmmdir/final.mdl | grep pdfs | awk '{print $NF}'` || exit 1;

echo ---------------------------------------------------------------------
echo "Generate alignment and prepare fMLLR features"
echo ---------------------------------------------------------------------
# Alignment on the training data
if [ ! -d ${gmmdir}_ali ]; then
  echo "Generate alignment on train"
  steps/align_fmllr.sh --nj 24 --cmd "$train_cmd" \
    data/train data/lang $gmmdir ${gmmdir}_ali || exit 1
fi

# Generate the fbank features. We generate 29-dimensional fbanks on each frame; fbank.conf is overwritten here.
echo "--num-mel-bins=$fbank_dim" > conf/fbank.conf
mkdir -p $working_dir/data
for set in train dev test; do
  if [ ! -d $working_dir/data/$set ]; then
    cp -r data/$set $working_dir/data/$set
    ( cd $working_dir/data/$set; rm -rf {cmvn,feats}.scp split*; )
    steps/make_fbank.sh --cmd "$train_cmd" --nj 8 $working_dir/data/$set $working_dir/_log $working_dir/_fbank || exit 1;
    steps/compute_cmvn_stats.sh $working_dir/data/$set $working_dir/_log $working_dir/_fbank || exit 1;
  fi
done

echo ---------------------------------------------------------------------
echo "Creating training and validation data (pfiles)"
echo ---------------------------------------------------------------------
# By default, inputs include 29 frames (+/-14) of 29-dimensional log-scale filter-banks,
# so that we take each frame as an image.
if [ ! -f $working_dir/train.pfile.done ]; then
  steps_deeplearn/build_nnet_pfile.sh --cmd "$train_cmd" --every-nth-frame 1 --norm-vars true \
    --do-split true --pfile-unit-size 5 --cv-ratio 0.05 \
    --splice-opts "$splice_opts" --input-dim 841 \
    $working_dir/data/train ${gmmdir}_ali $working_dir || exit 1
  ( cd $working_dir; rm concat.pfile; )
  touch $working_dir/train.pfile.done
fi

echo ---------------------------------------------------------------------
echo "Train SPN acoustic model"
echo ---------------------------------------------------------------------
feat_dim=$(cat $working_dir/train.pfile |head |grep num_features| awk '{print $2}') || exit 1;

if [ ! -f $working_dir/spn.fine.done ]; then
  echo "$0: Training SPN"
  $cmd $working_dir/log/spn.fine.log \
    export PYTHONPATH=$PYTHONPATH:`pwd`/kaldi-deeplearn/ \; \
    $pythonCMD kaldi-deeplearn/train_spn.py \
                          --train-data "$working_dir/train.pfile" \
                          --valid-data "$working_dir/valid.pfile" \
                          --num-outputs "$num_pdfs" \
                          --wdir $working_dir \
                          --output-file $working_dir/spn_conv.fnn \
                          --weight-output-file $working_dir/dnn.nnet \
                          --deeplearn-path $deeplearn_path \
                          --gpu-mem $gpu_mem_limit || exit 1;
  touch $working_dir/spn.fine.done
  $delete_pfile && rm -rf $working_dir/*.pfile
fi

##################################################################################

echo "Dump convolution activations on dev and test"
mkdir -p $working_dir/data_conv
for set in dev test; do
  if [ ! -f $working_dir/conv.feat.$set.done ]; then
    cp -r $working_dir/data/$set $working_dir/data_conv/$set
    ( cd $working_dir/data_conv/$set; rm -rf {cmvn,feats}.scp split*; )
  fi
  
  if [ ! -f $working_dir/txt.feat.$set.done ]; then
    echo "Txt format of fbank features on $set"
    # generate the txt format of fbank features
    steps_deeplearn/generate_txt_fbank.sh --cmd "$train_cmd"  \
      --input_splice_opts "$splice_opts" --norm-vars true \
      $working_dir/data/$set $working_dir/_log $working_dir || exit 1;
    if [ ! -f $working_dir/fbank_txt_${set}.ark ]; then
      echo "No fbank_txt_${set}.ark was generated" && exit 1;
    fi
    touch $working_dir/txt.feat.$set.done
  fi
  if [ ! -f $working_dir/conv.feat.$set.done ]; then
    mkdir -p $working_dir/_conv
    mkdir -p $working_dir/conv_${set}
    echo "Input txt features to the conv net"
    # Now we switch to GPU.
    $cmd $working_dir/_log/conv.feat.$set.log \
      export PYTHONPATH=$PYTHONPATH:`pwd`/kaldi-deeplearn/ \; \
      $pythonCMD kaldi-deeplearn/eval_spn.py \
                --ark-file $working_dir/fbank_txt_${set}.ark \
                --model-file $working_dir/spn_conv.fnn \
                --wdir $working_dir/conv_${set} \
                --deeplearn-path $deeplearn_path \
                --output-file-prefix $working_dir/_conv/conv_$set || exit 1;
    cp $working_dir/_conv/conv_${set}.scp $working_dir/data_conv/$set/feats.scp

    # It's critical to generate "fake" CMVN states here.
    steps/compute_cmvn_stats.sh --fake \
      $working_dir/data_conv/$set $working_dir/_log $working_dir/_conv || exit 1;  
 
    touch $working_dir/conv.feat.$set.done
  fi
done

echo ---------------------------------------------------------------------
echo "Decoding the final system"
echo ---------------------------------------------------------------------
if [ ! -f  $working_dir/decode.done ]; then
  cp $gmmdir/final.mdl $working_dir || exit 1;  # copy final.mdl for scoring
  graph_dir=$gmmdir/graph
  # No splicing on conv feats. So we reset the splice_opts
  echo "--left-context=0 --right-context=0" > $working_dir/splice_opts
  # Decode
  steps_deeplearn/decode_dnn.sh --nj 8 --scoring-opts "--min-lmwt 1 --max-lmwt 8" --cmd "$decode_cmd" --norm-vars false \
    $graph_dir $working_dir/data_conv/dev ${gmmdir}_ali $working_dir/decode_dev || exit 1;
  steps_deeplearn/decode_dnn.sh --nj 8 --scoring-opts "--min-lmwt 1 --max-lmwt 8" --cmd "$decode_cmd" --norm-vars false \
    $graph_dir $working_dir/data_conv/test ${gmmdir}_ali $working_dir/decode_test || exit 1;

  touch $working_dir/decode.done
fi

echo ---------------------------------------------------------------------
echo "Finished decoding. Computing WER"
echo ---------------------------------------------------------------------
for x in $working_dir/decode*; do [ -d $x ] && echo $x | grep "${1:-.*}" >/dev/null && grep WER $x/wer_* 2>/dev/null | utils/best_wer.sh; done
for x in $working_dir/decode*; do [ -d $x ] && echo $x | grep "${1:-.*}" >/dev/null && grep Sum $x/score_*/*.sys 2>/dev/null | utils/best_wer.sh; done
