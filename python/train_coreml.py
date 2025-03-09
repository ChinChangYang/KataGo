#!/usr/bin/python3
import sys
import os
import argparse
import random
import time
import logging
import json
import datetime
import gc
import shutil
import numpy as np
from collections import defaultdict

import torch
import torch.nn
import torch.optim
import torch.distributed
import torch.multiprocessing
from torch.optim.swa_utils import AveragedModel
from torch.optim.lr_scheduler import CosineAnnealingLR

import modelconfigs
from model_pytorch import Model
from metrics_pytorch import Metrics
import load_model
import data_processing_pytorch
from metrics_logging import accumulate_metrics, log_metrics, clear_metric_nonfinite

# PRUNE
from coremltools.optimize.torch.pruning import (
    MagnitudePruner,
    MagnitudePrunerConfig,
    ModuleMagnitudePrunerConfig
)
from coremltools.optimize.torch.pruning.pruning_scheduler import (
    PolynomialDecayScheduler
)

# HANDLE COMMAND AND ARGS -------------------------------------------------------------------

def get_args():

    description = """
    Train neural net on Go positions from npz files of batches from selfplay.
    """

    parser = argparse.ArgumentParser(description=description,add_help=False)
    required_args = parser.add_argument_group('required arguments')
    optional_args = parser.add_argument_group('optional arguments')
    optional_args.add_argument(
        '-h',
        '--help',
        action='help',
        default=argparse.SUPPRESS,
        help='show this help message and exit'
    )

    required_args.add_argument('-traindir', help='Dir to write to for recording training results', required=True)
    required_args.add_argument('-datadir', help='Directory with a train and val subdir of npz data, output by shuffle.py', required=True)
    optional_args.add_argument('-exportdir', help='Directory to export models periodically', required=False)
    optional_args.add_argument('-exportprefix', help='Prefix to append to names of models', required=False)
    optional_args.add_argument('-initial-checkpoint', help='If no training checkpoint exists, initialize from this checkpoint', required=False)

    required_args.add_argument('-pos-len', help='Spatial edge length of expected training data, e.g. 19 for 19x19 Go', type=int, required=True)
    required_args.add_argument('-batch-size', help='Per-GPU batch size to use for training', type=int, required=True)
    optional_args.add_argument('-samples-per-epoch', default=1000000, help='Number of data samples to consider as one epoch', type=int, required=False)
    optional_args.add_argument('-model-kind', help='String name for what model config to use', required=False)
    optional_args.add_argument('-lr-scale', default=1.0, help='LR multiplier on the hardcoded schedule', type=float, required=False)
    optional_args.add_argument('-swa-period-samples', help='How frequently to average an SWA sample, in samples', type=float, required=False)
    optional_args.add_argument('-swa-scale', default=8.0, help='Number of samples to average in expectation together for SWA', type=float, required=False)

    optional_args.add_argument('-multi-gpus', help='Use multiple gpus, comma-separated device ids', required=False)

    optional_args.add_argument('-max-epochs-this-instance', help='Terminate training after this many more epochs', type=int, required=False)
    optional_args.add_argument('-max-training-samples', help='Terminate training after about this many training steps in samples', type=int, required=False)
    optional_args.add_argument('-max-train-steps-since-last-reload', help='Approx total of training allowed if shuffling stops', type=float, required=False)
    optional_args.add_argument('-stop-when-train-bucket-limited', help='Terminate due to train bucket rather than waiting for more', required=False, action='store_true')
    optional_args.add_argument('-max-val-samples', help='Approx max of validation samples per epoch', type=int, required=False)
    optional_args.add_argument('-randomize-val', help='Randomize order of validation files', required=False, action='store_true')
    optional_args.add_argument('-no-export', help='Do not export models', required=False, action='store_true')
    optional_args.add_argument('-no-repeat-files', help='Track what shuffled data was used and do not repeat, even when killed and resumed', required=False, action='store_true')
    optional_args.add_argument('-quit-if-no-data', help='If no data, quit instead of waiting for data', required=False, action='store_true')

    optional_args.add_argument('-soft-policy-weight-scale', type=float, default=8.0, help='Soft policy loss coeff', required=False)
    optional_args.add_argument('-disable-optimistic-policy', help='Disable optimistic policy', required=False, action='store_true')
    optional_args.add_argument('-meta-kata-only-soft-policy', help='Mask soft policy on non-kata rows using sgfmeta', required=False, action='store_true')
    optional_args.add_argument('-value-loss-scale', type=float, default=0.6, help='Additional value loss coeff', required=False)
    optional_args.add_argument('-td-value-loss-scales', type=str, default="0.6,0.6,0.6", help='Additional td value loss coeffs, 3 comma separated values', required=False)
    optional_args.add_argument('-seki-loss-scale', type=float, default=1.0, help='Additional seki loss coeff', required=False)
    optional_args.add_argument('-variance-time-loss-scale', type=float, default=1.0, help='Additional variance time loss coeff', required=False)

    optional_args.add_argument('-main-loss-scale', type=float, default=0.2, help='Loss factor scale for main head', required=False)
    optional_args.add_argument('-intermediate-loss-scale', type=float, default=0.8, help='Loss factor scale for intermediate head', required=False)
    optional_args.add_argument('-radam-weight-decay', type=float, default=5e-2, help='Weight decay for RAdam optimizer', required=False)
    optional_args.add_argument('-lr-scheduler-period-samples', type=float, default=5e4, help='How frequently to update learning rate, in samples', required=False)
    optional_args.add_argument('-pruner-sparsity', type=float, default=0.0, help='Target sparsity of weight pruner', required=False)
    optional_args.add_argument('-pruner-period-samples', type=float, default=5e4, help='How frequently to update pruner, in samples', required=False)

    args = vars(parser.parse_args())

    return args


def make_dirs(args):
    traindir = args["traindir"]
    exportdir = args["exportdir"]

    if not os.path.exists(traindir):
        os.makedirs(traindir)
    if exportdir is not None and not os.path.exists(exportdir):
        os.makedirs(exportdir)


def main():
    args = get_args()
    make_dirs(args)

    traindir = args["traindir"]
    datadir = args["datadir"]
    exportdir = args["exportdir"]
    exportprefix = args["exportprefix"]
    initial_checkpoint = args["initial_checkpoint"]

    pos_len = args["pos_len"]
    batch_size = args["batch_size"]
    samples_per_epoch = args["samples_per_epoch"]
    model_kind = args["model_kind"]
    lr_scale = args["lr_scale"]
    swa_period_samples = args["swa_period_samples"]
    swa_scale = args["swa_scale"]

    max_training_samples = args["max_training_samples"]
    max_train_steps_since_last_reload = args["max_train_steps_since_last_reload"]
    max_val_samples = args["max_val_samples"]
    randomize_val = args["randomize_val"]
    no_export = args["no_export"]
    no_repeat_files = args["no_repeat_files"]
    quit_if_no_data = args["quit_if_no_data"]

    soft_policy_weight_scale = args["soft_policy_weight_scale"]
    disable_optimistic_policy = args["disable_optimistic_policy"]
    meta_kata_only_soft_policy = args["meta_kata_only_soft_policy"]
    value_loss_scale = args["value_loss_scale"]
    td_value_loss_scales = [float(x) for x in args["td_value_loss_scales"].split(",")]
    seki_loss_scale = args["seki_loss_scale"]
    variance_time_loss_scale = args["variance_time_loss_scale"]

    main_loss_scale = args["main_loss_scale"]
    intermediate_loss_scale = args["intermediate_loss_scale"]
    radam_weight_decay = args["radam_weight_decay"]
    lr_scheduler_period_samples = args["lr_scheduler_period_samples"]
    pruner_sparsity = args["pruner_sparsity"]
    pruner_period_samples = args["pruner_period_samples"]

    if swa_period_samples is None:
        swa_period_samples = max(1, samples_per_epoch // 2)

    num_shortterm_checkpoints_to_keep = 4

    # SET UP LOGGING -------------------------------------------------------------

    logging.root.handlers = []
    logging.basicConfig(
        level=logging.INFO,
        format="%(message)s",
        handlers=[
            logging.FileHandler(os.path.join(traindir,f"train.log"), mode="a"),
            logging.StreamHandler()
        ],
    )
    np.set_printoptions(linewidth=150)

    logging.info(str(sys.argv))

    my_gpu_id = 0
    logging.info("Using MPS device")
    device = torch.device("mps", my_gpu_id)

    seed = int.from_bytes(os.urandom(7), sys.byteorder)
    logging.info(f"Seeding torch with {seed}")
    torch.manual_seed(seed)

    # LOAD MODEL ---------------------------------------------------------------------

    def get_checkpoint_path():
        return os.path.join(traindir,"checkpoint.ckpt")
    def get_checkpoint_prev_path(i):
        return os.path.join(traindir,f"checkpoint_prev{i}.ckpt")

    def save(ddp_model, swa_model, optimizer, scheduler, metrics_obj, running_metrics, train_state, last_val_metrics, path=None):
        state_dict = {}
        state_dict["model"] = ddp_model.state_dict()
        state_dict["optimizer"] = optimizer.state_dict()
        state_dict["scheduler"] = scheduler.state_dict()
        state_dict["metrics"] = metrics_obj.state_dict()
        state_dict["running_metrics"] = running_metrics
        state_dict["train_state"] = train_state
        state_dict["last_val_metrics"] = last_val_metrics
        state_dict["config"] = model_config

        if swa_model is not None:
            state_dict["swa_model"] = swa_model.state_dict()

        if path is not None:
            logging.info("Saving checkpoint: " + path)
            torch.save(state_dict, path + ".tmp")
            time.sleep(1)
            os.replace(path + ".tmp", path)
        else:
            logging.info("Saving checkpoint: " + get_checkpoint_path())
            for i in reversed(range(num_shortterm_checkpoints_to_keep-1)):
                if os.path.exists(get_checkpoint_prev_path(i)):
                    os.replace(get_checkpoint_prev_path(i), get_checkpoint_prev_path(i+1))
            if os.path.exists(get_checkpoint_path()):
                shutil.copy(get_checkpoint_path(), get_checkpoint_prev_path(0))
            torch.save(state_dict, get_checkpoint_path() + ".tmp")
            os.replace(get_checkpoint_path() + ".tmp", get_checkpoint_path())

    def get_scheduler_tmax(train_state, period_samples):
        if max_training_samples is not None:
            if train_state["global_step_samples"] is not None:
                global_step_samples = train_state["global_step_samples"]
            else:
                global_step_samples = 0
            T_max = int((max_training_samples - global_step_samples) // period_samples)
            logging.info(f"Scheduler T_max={T_max}, derived by max={max_training_samples}, now={global_step_samples}, period={period_samples}")
        else:
            T_max = 2
            logging.info(f"Scheduler T_max={T_max}, default")

        return T_max

    def new_optimizer(raw_model, train_state):
        optimizer = torch.optim.RAdam(raw_model.parameters(), lr=lr_scale, weight_decay=radam_weight_decay, decoupled_weight_decay=True)
        T_max = get_scheduler_tmax(train_state, lr_scheduler_period_samples)
        scheduler = CosineAnnealingLR(optimizer, T_max=T_max)

        return optimizer, scheduler

    def new_pruner(raw_model, train_state) -> MagnitudePruner:
        if pruner_sparsity is None:
            target_sparsity = 0.0
        else:
            target_sparsity = pruner_sparsity

        T_max = get_scheduler_tmax(train_state, pruner_period_samples)
        T_max = T_max // 2 # Only step parsity for the first half
        pruner_scheduler = PolynomialDecayScheduler(update_steps=list(range(0, T_max, 1)))
        global_pruner_config = ModuleMagnitudePrunerConfig(target_sparsity=target_sparsity, scheduler=pruner_scheduler)
        pruner_config = MagnitudePrunerConfig()
        pruner_config.set_global(global_pruner_config)
        pruner = MagnitudePruner(raw_model, pruner_config)
        pruner.prepare(inplace=True)

        return pruner

    def load():
        if not os.path.exists(get_checkpoint_path()):
            logging.info("No preexisting checkpoint found at: " + get_checkpoint_path())
            for i in range(num_shortterm_checkpoints_to_keep):
                if os.path.exists(get_checkpoint_prev_path(i)):
                    raise Exception(f"No preexisting checkpoint found, but {get_checkpoint_prev_path(i)} exists, something is wrong with the training dir")

            if initial_checkpoint is not None:
                if os.path.exists(initial_checkpoint):
                    logging.info("Using initial checkpoint: {initial_checkpoint}")
                    path_to_load_from = initial_checkpoint
                else:
                    raise Exception("No preexisting checkpoint found, initial checkpoint provided is invalid: {initial_checkpoint}")
            else:
                path_to_load_from = None
        else:
            path_to_load_from = get_checkpoint_path()

        if path_to_load_from is None:
            logging.info("Initializing new model!")
            assert model_kind is not None, "Model kind is none or unspecified but the model is being created fresh"
            model_config = modelconfigs.config_of_name[model_kind]
            logging.info(str(model_config))
            raw_model = Model(model_config,pos_len)
            raw_model.initialize()

            raw_model.to(device)
            ddp_model = raw_model

            swa_model = None
            if swa_scale is not None:
                new_factor = 1.0 / swa_scale
                ema_avg = lambda avg_param, cur_param, num_averaged: avg_param + new_factor * (cur_param - avg_param)
                swa_model = AveragedModel(raw_model, avg_fn=ema_avg)

            metrics_obj = Metrics(batch_size,world_size=1,raw_model=raw_model)
            running_metrics = {}
            train_state = {}
            last_val_metrics = {}

            train_state["global_step_samples"] = 0

            with torch.no_grad():
                (modelnorm_normal, _, _, _, _) = Metrics.get_model_norms(raw_model)
                modelnorm_normal_baseline = modelnorm_normal.detach().cpu().item()
                train_state["modelnorm_normal_baseline"] = modelnorm_normal_baseline
                logging.info(f"Model norm normal baseline computed: {modelnorm_normal_baseline}")

            optimizer, scheduler = new_optimizer(raw_model, train_state)
            pruner = new_pruner(raw_model, train_state)

            return (model_config, ddp_model, raw_model, swa_model, optimizer, scheduler, metrics_obj, running_metrics, train_state, last_val_metrics, pruner)
        else:
            state_dict = torch.load(path_to_load_from, map_location=device)
            model_config = state_dict["config"] if "config" in state_dict else modelconfigs.config_of_name[model_kind]
            logging.info(str(model_config))
            raw_model = Model(model_config,pos_len)
            raw_model.initialize()

            train_state = {}
            if "train_state" in state_dict:
                train_state = state_dict["train_state"]
            else:
                logging.info("WARNING: Train state not found in state dict, using fresh train state")

            # Do this before loading the state dict, while the model is initialized to fresh values, to get a good baseline
            if "modelnorm_normal_baseline" not in train_state:
                logging.info("Computing modelnorm_normal_baseline since not in train state")
                with torch.no_grad():
                    (modelnorm_normal, modelnorm_normal_gamma, modelnorm_output, modelnorm_noreg, modelnorm_output_noreg) = Metrics.get_model_norms(raw_model)
                    modelnorm_normal_baseline = modelnorm_normal.detach().cpu().item()
                    train_state["modelnorm_normal_baseline"] = modelnorm_normal_baseline
                    logging.info(f"Model norm normal baseline computed: {modelnorm_normal_baseline}")

            # Strip off any "module." from when the model was saved with DDP or other things
            model_state_dict = load_model.load_model_state_dict(state_dict)
            raw_model.load_state_dict(model_state_dict)

            raw_model.to(device)
            ddp_model = raw_model

            swa_model = None
            if swa_scale is not None:
                new_factor = 1.0 / swa_scale
                ema_avg = lambda avg_param, cur_param, num_averaged: avg_param + new_factor * (cur_param - avg_param)
                swa_model = AveragedModel(raw_model, avg_fn=ema_avg)
                swa_model_state_dict = load_model.load_swa_model_state_dict(state_dict)
                if swa_model_state_dict is not None:
                    swa_model.load_state_dict(swa_model_state_dict)

            metrics_obj = Metrics(batch_size,world_size=1,raw_model=raw_model)
            if "metrics" in state_dict:
                metrics_obj.load_state_dict(state_dict["metrics"])
            else:
                logging.info("WARNING: Metrics not found in state dict, using fresh metrics")

            running_metrics = {}
            if "running_metrics" in state_dict:
                running_metrics = state_dict["running_metrics"]
            else:
                logging.info("WARNING: Running metrics not found in state dict, using fresh running metrics")

            last_val_metrics = {}
            if "last_val_metrics" in state_dict:
                last_val_metrics = state_dict["last_val_metrics"]
            else:
                logging.info("WARNING: Running metrics not found in state dict, using fresh last val metrics")

            optimizer, scheduler = new_optimizer(raw_model, train_state)

            if "optimizer" in state_dict:
                try:
                    optimizer.load_state_dict(state_dict["optimizer"])
                except ValueError as e:
                    logging.warning("WARNING: Failed to load optimizer state dict due to error: %s. Using fresh optimizer", e)
            else:
                logging.info("WARNING: Optimizer not found in state dict, using fresh optimizer")

            if "scheduler" in state_dict:
                scheduler.load_state_dict(state_dict["scheduler"])
            else:
                logging.info("WARNING: Scheduler not found in state dict, using fresh scheduler")

            pruner = new_pruner(raw_model, train_state)

            return (model_config, ddp_model, raw_model, swa_model, optimizer, scheduler, metrics_obj, running_metrics, train_state, last_val_metrics, pruner)

    (model_config, ddp_model, raw_model, swa_model, optimizer, scheduler, metrics_obj, running_metrics, train_state, last_val_metrics, pruner) = load()


    if "global_step_samples" not in train_state:
        train_state["global_step_samples"] = 0
    if "train_steps_since_last_reload" not in train_state:
        train_state["train_steps_since_last_reload"] = 0
    if "export_cycle_counter" not in train_state:
        train_state["export_cycle_counter"] = 0
    if "total_num_data_rows" not in train_state:
        train_state["total_num_data_rows"] = 0
    if "old_train_data_dirs" not in train_state:
        train_state["old_train_data_dirs"] = []
    if "data_files_used" not in train_state:
        train_state["data_files_used"] = set()
    if "swa_sample_accum" not in train_state:
        train_state["swa_sample_accum"] = 0.0
    if "scheduler_sample_accum" not in train_state:
        train_state["scheduler_sample_accum"] = 0.0
    if "pruner_sample_accum" not in train_state:
        train_state["pruner_sample_accum"] = 0.0

    logging.info(f"swa_period_samples {swa_period_samples}")
    logging.info(f"swa_scale {swa_scale}")
    logging.info(f"soft_policy_weight_scale {soft_policy_weight_scale}")
    logging.info(f"disable_optimistic_policy {disable_optimistic_policy}")
    logging.info(f"meta_kata_only_soft_policy {meta_kata_only_soft_policy}")
    logging.info(f"value_loss_scale {value_loss_scale}")
    logging.info(f"td_value_loss_scales {td_value_loss_scales}")
    logging.info(f"seki_loss_scale {seki_loss_scale}")
    logging.info(f"variance_time_loss_scale {variance_time_loss_scale}")
    logging.info(f"main_loss_scale {main_loss_scale}")
    logging.info(f"intermediate_loss_scale {intermediate_loss_scale}")

    # Print all model parameters just to get a summary
    total_num_params = 0
    total_trainable_params = 0
    logging.info("Parameters in model:")
    for name, param in raw_model.named_parameters():
        product = 1
        for dim in param.shape:
            product *= int(dim)
        if param.requires_grad:
            total_trainable_params += product
        total_num_params += product
        logging.info(f"{name}, {list(param.shape)}, {product} params")
    logging.info(f"Total num params: {total_num_params}")
    logging.info(f"Total trainable params: {total_trainable_params}")

    # DATA RELOADING GENERATOR ------------------------------------------------------------

    # Some globals
    last_curdatadir = None
    trainfilegenerator = None
    vdatadir = None

    def maybe_reload_training_data(last_curdatadir, trainfilegenerator, vdatadir):
        while True:
            curdatadir = os.path.realpath(datadir)

            # Different directory - new shuffle
            if curdatadir != last_curdatadir:
                if not os.path.exists(curdatadir):
                    if quit_if_no_data:
                        logging.info("Shuffled data path does not exist, there seems to be no data or not enough data yet, qutting: %s" % curdatadir)
                        sys.exit(0)
                    logging.info("Shuffled data path does not exist, there seems to be no shuffled data yet, waiting and trying again later: %s" % curdatadir)
                    time.sleep(30)
                    continue

                trainjsonpath = os.path.join(curdatadir,"train.json")
                if not os.path.exists(trainjsonpath):
                    if quit_if_no_data:
                        logging.info("Shuffled data train.json file does not exist, there seems to be no data or not enough data yet, qutting: %s" % trainjsonpath)
                        sys.exit(0)
                    logging.info("Shuffled data train.json file does not exist, there seems to be no shuffled data yet, waiting and trying again later: %s" % trainjsonpath)
                    time.sleep(30)
                    continue

                logging.info("Updated training data: " + curdatadir)
                last_curdatadir = curdatadir

                with open(trainjsonpath) as f:
                    datainfo = json.load(f)
                    train_state["total_num_data_rows"] = datainfo["range"][1]

                logging.info("Train steps since last reload: %.0f -> 0" % train_state["train_steps_since_last_reload"])
                train_state["train_steps_since_last_reload"] = 0

                # Load training data files
                tdatadir = os.path.join(curdatadir,"train")
                train_files = [os.path.join(tdatadir,fname) for fname in os.listdir(tdatadir) if fname.endswith(".npz")]
                epoch0_train_files = [path for path in train_files if path not in train_state["data_files_used"]]
                if no_repeat_files:
                    logging.info(f"Dropping {len(train_files)-len(epoch0_train_files)}/{len(train_files)} files in: {tdatadir} as already used")
                else:
                    logging.info(f"Skipping {len(train_files)-len(epoch0_train_files)}/{len(train_files)} files in: {tdatadir} as already used first pass")

                if len(train_files) <= 0 or (no_repeat_files and len(epoch0_train_files) <= 0):
                    if quit_if_no_data:
                        logging.info(f"No new training files found in: {tdatadir}, quitting")
                        sys.exit(0)
                    logging.info(f"No new training files found in: {tdatadir}, waiting 30s and trying again")
                    time.sleep(30)
                    continue

                # Update history of what training data we used
                if tdatadir not in train_state["old_train_data_dirs"]:
                    train_state["old_train_data_dirs"].append(tdatadir)
                # Clear out tracking of sufficiently old files
                while len(train_state["old_train_data_dirs"]) > 20:
                    old_dir = train_state["old_train_data_dirs"][0]
                    train_state["old_train_data_dirs"] = train_state["old_train_data_dirs"][1:]
                    for filename in list(train_state["data_files_used"]):
                        if filename.startswith(old_dir):
                            train_state["data_files_used"].remove(filename)

                def train_files_gen():
                    train_files_shuffled = epoch0_train_files.copy()
                    while True:
                        random.shuffle(train_files_shuffled)
                        for filename in train_files_shuffled:
                            logging.info("Yielding training file for dataset: " + filename)
                            train_state["data_files_used"].add(filename)
                            yield filename
                        if no_repeat_files:
                            break
                        else:
                            train_files_shuffled = train_files.copy()
                            train_state["data_files_used"] = set()

                trainfilegenerator = train_files_gen()
                vdatadir = os.path.join(curdatadir,"val")

            # Same directory as before, no new shuffle
            else:
                if max_train_steps_since_last_reload is not None:
                    if train_state["train_steps_since_last_reload"] + 0.99 * samples_per_epoch > max_train_steps_since_last_reload:
                        logging.info(
                            "Too many train steps since last reload, waiting 5m and retrying (current %f)" %
                            train_state["train_steps_since_last_reload"]
                        )
                        time.sleep(300)
                        continue

            break

        return (last_curdatadir, trainfilegenerator, vdatadir)

    # Load all the files we should train on during a subepoch
    def get_files_for_subepoch(trainfilegenerator):
        num_batches_per_epoch = int(round(samples_per_epoch / batch_size))
        num_batches_per_subepoch = num_batches_per_epoch

        # Pick enough files to get the number of batches we want
        train_files_to_use = []
        batches_to_use_so_far = 0
        found_enough = False
        for filename in trainfilegenerator:
            jsonfilename = os.path.splitext(filename)[0] + ".json"
            with open(jsonfilename) as f:
                trainfileinfo = json.load(f)

            num_batches_this_file = trainfileinfo["num_rows"] // batch_size
            if num_batches_this_file <= 0:
                continue

            if batches_to_use_so_far + num_batches_this_file > num_batches_per_subepoch:
                # If we're going over the desired amount, randomly skip the file with probability equal to the
                # proportion of batches over - this makes it so that in expectation, we have the desired number of batches
                if batches_to_use_so_far > 0 and random.random() >= (batches_to_use_so_far + num_batches_this_file - num_batches_per_subepoch) / num_batches_this_file:
                    found_enough = True
                    break

            train_files_to_use.append(filename)
            batches_to_use_so_far += num_batches_this_file

            #Sanity check - load a max of 100000 files.
            if batches_to_use_so_far >= num_batches_per_subepoch or len(train_files_to_use) > 100000:
                found_enough = True
                break

        if found_enough:
            return train_files_to_use
        return None

    # METRICS -----------------------------------------------------------------------------------
    def detensorify_metrics(metrics):
        ret = {}
        for key in metrics:
            if isinstance(metrics[key], torch.Tensor):
                ret[key] = metrics[key].detach().cpu().item()
            else:
                ret[key] = metrics[key]
        return ret

    train_metrics_out = open(os.path.join(traindir,"metrics_train.json"),"a")
    val_metrics_out = open(os.path.join(traindir,"metrics_val.json"),"a")

    # TRAIN! -----------------------------------------------------------------------------------

    num_epochs_this_instance = 0
    print_train_loss_every_batches = 100

    if "sums" not in running_metrics:
        running_metrics["sums"] = defaultdict(float)
    else:
        running_metrics["sums"] = defaultdict(float,running_metrics["sums"])
    if "weights" not in running_metrics:
        running_metrics["weights"] = defaultdict(float)
    else:
        running_metrics["weights"] = defaultdict(float,running_metrics["weights"])

    logging.info("Training in FP32.")

    if max_training_samples is not None and train_state["global_step_samples"] >= max_training_samples:
        global_step_samples = train_state["global_step_samples"]
        logging.info(f"Hit max training samples ({global_step_samples} >= {max_training_samples}), done")
    else:
        last_curdatadir, trainfilegenerator, vdatadir = maybe_reload_training_data(last_curdatadir, trainfilegenerator, vdatadir)

        logging.info("GC collect")
        gc.collect()

        clear_metric_nonfinite(running_metrics["sums"], running_metrics["weights"])

        logging.info("=========================================================================")
        logging.info("BEGINNING NEXT EPOCH " + str(num_epochs_this_instance))
        logging.info("=========================================================================")
        logging.info("Current time: " + str(datetime.datetime.now()))
        logging.info("Global step: %d samples" % (train_state["global_step_samples"]))
        if max_training_samples is not None:
            logging.info("Max step:    %d samples" % (max_training_samples))
        logging.info("Currently up to data row " + str(train_state["total_num_data_rows"]))
        logging.info(f"Training dir: {traindir}")
        logging.info(f"Export dir: {exportdir}")

        lr_right_now = scheduler.get_last_lr()[0]
        normal_weight_decay_right_now = radam_weight_decay

        # SUB EPOCH LOOP -----------
        batch_count_this_epoch = 0
        last_train_stats_time = time.perf_counter()

        train_files_to_use = get_files_for_subepoch(trainfilegenerator)
        while train_files_to_use is None or len(train_files_to_use) <= 0:
            if quit_if_no_data:
                logging.info("Not enough data files to fill a subepoch! Quitting.")
                sys.exit(0)
            logging.info("Not enough data files to fill a subepoch! Waiting 5m before retrying.")
            time.sleep(300)
            last_curdatadir, trainfilegenerator, vdatadir = maybe_reload_training_data(last_curdatadir, trainfilegenerator, vdatadir)
            train_files_to_use = get_files_for_subepoch(trainfilegenerator)

        # Wait briefly just in case to reduce chance of races with filesystem or anything else
        time.sleep(5)

        logging.info("Beginning training subepoch!")
        logging.info("This subepoch, using files: " + str(train_files_to_use))
        logging.info("Currently up to data row " + str(train_state["total_num_data_rows"]))

        # Log current learning rate
        current_counter = str(train_state["export_cycle_counter"])
        current_lr = scheduler.get_last_lr()[0]
        current_samples = train_state["global_step_samples"]
        logging.info(f"Current Learning Rate [{current_counter}]: {current_lr} at {current_samples} samples")

        # Log current pruner step count
        logging.info(f"Pruner step count: {pruner._step_count}")

        for batch in data_processing_pytorch.read_npz_training_data(
            train_files_to_use,
            batch_size,
            world_size=1,
            rank=0,
            pos_len=pos_len,
            device=device,
            randomize_symmetries=True,
            include_meta=raw_model.get_has_metadata_encoder(),
            model_config=model_config
        ):
            optimizer.zero_grad(set_to_none=True)

            model_outputs = ddp_model(
                batch["binaryInputNCHW"],
                batch["globalInputNC"],
                input_meta=(batch["metadataInputNC"] if raw_model.get_has_metadata_encoder() else None),
                extra_outputs=None,
            )

            postprocessed = raw_model.postprocess_output(model_outputs)
            metrics = metrics_obj.metrics_dict_batchwise(
                raw_model,
                postprocessed,
                extra_outputs=None,
                batch=batch,
                is_training=True,
                soft_policy_weight_scale=soft_policy_weight_scale,
                disable_optimistic_policy=disable_optimistic_policy,
                meta_kata_only_soft_policy=meta_kata_only_soft_policy,
                value_loss_scale=value_loss_scale,
                td_value_loss_scales=td_value_loss_scales,
                seki_loss_scale=seki_loss_scale,
                variance_time_loss_scale=variance_time_loss_scale,
                main_loss_scale=main_loss_scale,
                intermediate_loss_scale=intermediate_loss_scale,
            )

            # DDP averages loss across instances, so to preserve LR as per-sample lr, we scale by world size.
            loss = metrics["loss_sum"]

            # Reduce gradients across DDP
            loss.backward()

            metrics["pslr_batch"] = lr_right_now
            metrics["wdnormal_batch"] = normal_weight_decay_right_now

            optimizer.step()

            batch_count_this_epoch += 1
            train_state["train_steps_since_last_reload"] += batch_size
            train_state["global_step_samples"] += batch_size

            metrics = detensorify_metrics(metrics)

            accumulate_metrics(running_metrics["sums"], running_metrics["weights"], metrics, batch_size, decay=0.999, new_weight=1.0)

            if batch_count_this_epoch % print_train_loss_every_batches == 0:
                t1 = time.perf_counter()
                timediff = t1 - last_train_stats_time
                last_train_stats_time = t1
                metrics["time_since_last_print"] = timediff
                log_metrics(running_metrics["sums"], running_metrics["weights"], metrics, train_metrics_out)

            # Perform learning rate scheduler
            train_state["scheduler_sample_accum"] += batch_size
            if train_state["scheduler_sample_accum"] >= lr_scheduler_period_samples:
                train_state["scheduler_sample_accum"] = 0
                scheduler.step()
                lr_right_now = scheduler.get_last_lr()[0]
                normal_weight_decay_right_now = radam_weight_decay

            train_state["pruner_sample_accum"] += batch_size
            if train_state["pruner_sample_accum"] >= pruner_period_samples:
                train_state["pruner_sample_accum"] = 0
                pruner.step()
                logging.info(f"Updated pruner step count: {pruner._step_count}")

            # Perform SWA
            if swa_model is not None and swa_scale is not None:
                train_state["swa_sample_accum"] += batch_size
                # Only snap SWA when lookahead slow params are in sync.
                if train_state["swa_sample_accum"] >= swa_period_samples:
                    train_state["swa_sample_accum"] = 0
                    logging.info("Accumulating SWA")
                    try:
                        swa_model.update_parameters(raw_model)
                    except RuntimeError as e:
                        logging.warning("WARNING: Failed to update SWA parameters due to error: %s. Skipping", e)

        logging.info("Finished training subepoch!")

        # END SUB EPOCH LOOP ------------

        train_state["export_cycle_counter"] += 1

        pruner.finalize(ddp_model, inplace=True)
        save(ddp_model, swa_model, optimizer, scheduler, metrics_obj, running_metrics, train_state, last_val_metrics)

        num_epochs_this_instance += 1

        # Validate
        logging.info("Beginning validation after epoch!")
        val_files = []
        if os.path.exists(vdatadir):
            val_files = [os.path.join(vdatadir,fname) for fname in os.listdir(vdatadir) if fname.endswith(".npz")]
        if randomize_val:
            random.shuffle(val_files)
        else:
            # Sort to ensure deterministic order to validation files in case we use only a subset
            val_files = sorted(val_files)
        if len(val_files) == 0:
            logging.info("No validation files, skipping validation step")
        else:
            with torch.no_grad():
                ddp_model.eval()
                val_metric_sums = defaultdict(float)
                val_metric_weights = defaultdict(float)
                metrics = defaultdict(float)
                val_samples = 0
                t0 = time.perf_counter()
                for batch in data_processing_pytorch.read_npz_training_data(
                    val_files,
                    batch_size,
                    world_size=1,  # Only the main process validates
                    rank=0,        # Only the main process validates
                    pos_len=pos_len,
                    device=device,
                    randomize_symmetries=True,
                    include_meta=raw_model.get_has_metadata_encoder(),
                    model_config=model_config
                ):
                    model_outputs = ddp_model(
                        batch["binaryInputNCHW"],
                        batch["globalInputNC"],
                        input_meta=(batch["metadataInputNC"] if raw_model.get_has_metadata_encoder() else None),
                    )
                    postprocessed = raw_model.postprocess_output(model_outputs)
                    metrics = metrics_obj.metrics_dict_batchwise(
                        raw_model,
                        postprocessed,
                        extra_outputs=None,
                        batch=batch,
                        is_training=False,
                        soft_policy_weight_scale=soft_policy_weight_scale,
                        disable_optimistic_policy=disable_optimistic_policy,
                        meta_kata_only_soft_policy=meta_kata_only_soft_policy,
                        value_loss_scale=value_loss_scale,
                        td_value_loss_scales=td_value_loss_scales,
                        seki_loss_scale=seki_loss_scale,
                        variance_time_loss_scale=variance_time_loss_scale,
                        main_loss_scale=main_loss_scale,
                        intermediate_loss_scale=intermediate_loss_scale,
                    )
                    metrics = detensorify_metrics(metrics)
                    accumulate_metrics(val_metric_sums, val_metric_weights, metrics, batch_size, decay=1.0, new_weight=1.0)
                    val_samples += batch_size
                    if max_val_samples is not None and val_samples > max_val_samples:
                        break
                    val_metric_sums["nsamp_train"] = running_metrics["sums"]["nsamp"]
                    val_metric_weights["nsamp_train"] = running_metrics["weights"]["nsamp"]
                    val_metric_sums["wsum_train"] = running_metrics["sums"]["wsum"]
                    val_metric_weights["wsum_train"] = running_metrics["weights"]["wsum"]
                last_val_metrics["sums"] = val_metric_sums
                last_val_metrics["weights"] = val_metric_weights
                log_metrics(val_metric_sums, val_metric_weights, metrics, val_metrics_out)
                t1 = time.perf_counter()
                logging.info(f"Validation took {t1-t0} seconds")
                ddp_model.train()

        logging.info("Export cycle counter = " + str(train_state["export_cycle_counter"]))

        if not no_export and exportdir is not None:
            # Export a model for testing, unless somehow it already exists
            modelname = "%s-s%d-d%d" % (
                exportprefix,
                train_state["global_step_samples"],
                train_state["total_num_data_rows"],
            )
            savepath = os.path.join(exportdir,modelname)
            savepathtmp = os.path.join(exportdir,modelname+".tmp")
            if os.path.exists(savepath):
                logging.info("NOT saving model, already exists at: " + savepath)
            else:
                os.mkdir(savepathtmp)
                logging.info("SAVING MODEL FOR EXPORT TO: " + savepath)
                save(ddp_model, swa_model, optimizer, scheduler, metrics_obj, running_metrics, train_state, last_val_metrics, path=os.path.join(savepathtmp,"model.ckpt"))
                time.sleep(2)
                os.rename(savepathtmp,savepath)

    train_metrics_out.close()
    val_metrics_out.close()


if __name__ == "__main__":
    main()
