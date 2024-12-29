from typing import List, Tuple, Optional, Union
import copy
from collections import OrderedDict
import torch
import torch.nn as nn
import torch.nn.functional as F
from timm.models.layers import DropPath, trunc_normal_

__all__ = ["transform_model"]


# ---------------------------
# Attention Module
# ---------------------------
class AttentionModule(nn.Module):
    """
    Attention module that applies channel-wise attention to the input tensor.
    It reduces the number of channels, applies activation, and then restores the channel dimension.
    """

    def __init__(self, channels: int, reduction: float = 0.0625) -> None:
        super().__init__()
        reduced_channels = max(
            1, int(channels * reduction)
        )  # Ensure at least one channel
        self.downsample = nn.Conv2d(
            channels, reduced_channels, kernel_size=1, stride=1, bias=True
        )
        self.upsample = nn.Conv2d(
            reduced_channels, channels, kernel_size=1, stride=1, bias=True
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        batch_size, channels, height, width = x.size()
        # Global average pooling
        pooled = F.avg_pool2d(x, kernel_size=(height, width))
        # Downsample and apply ReLU activation
        reduced = F.relu(self.downsample(pooled))
        # Upsample and apply sigmoid activation
        attention = torch.sigmoid(self.upsample(reduced)).view(
            batch_size, channels, 1, 1
        )
        # Apply attention to the input
        return x * attention


# ---------------------------
# Flexible Convolutional Block
# ---------------------------
class FlexibleBlock(nn.Module):
    """
    Flexible convolutional block that supports various configurations such as branches, attention, and activation.
    It can be reparameterized for inference to merge all branches into a single convolutional layer.
    """

    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        kernel_size: int,
        stride: int = 1,
        padding: int = 0,
        dilation: int = 1,
        groups: int = 1,
        infer: bool = False,
        use_attention: bool = False,
        use_activation: bool = True,
        use_scale: bool = True,
        num_branches: int = 1,
        activation_fn: nn.Module = nn.GELU(),
    ) -> None:
        super().__init__()
        self.infer = infer
        self.groups = groups
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self.kernel_size = kernel_size
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.num_branches = num_branches

        # Initialize attention module if needed
        self.attention = (
            AttentionModule(out_channels) if use_attention else nn.Identity()
        )

        # Initialize activation function if needed
        self.activation = activation_fn if use_activation else nn.Identity()

        if self.infer:
            # Single convolutional layer for inference
            self.conv = nn.Conv2d(
                in_channels,
                out_channels,
                kernel_size,
                stride,
                padding,
                dilation,
                groups,
                bias=True,
            )
        else:
            # Skip connection if input and output dimensions match and stride is 1
            self.skip_connection = (
                nn.BatchNorm2d(in_channels)
                if (out_channels == in_channels and stride == 1)
                else None
            )
            # Create multiple convolutional branches
            self.branches = nn.ModuleList(
                [self._conv_bn(kernel_size, padding) for _ in range(num_branches)]
                if num_branches > 0
                else []
            )
            # Optional scaling branch
            self.scale_branch = (
                self._conv_bn(1, 0) if (kernel_size > 1 and use_scale) else None
            )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.infer:
            # Inference mode: single convolution followed by activation and attention
            return self.activation(self.attention(self.conv(x)))

        # Initialize output with skip connection if available
        out = self.skip_connection(x) if self.skip_connection else 0
        # Add scaled branch output if available
        out += self.scale_branch(x) if self.scale_branch else 0
        # Add outputs from all branches
        for branch in self.branches:
            out += branch(x)
        # Apply activation and attention
        return self.activation(self.attention(out))

    def reparameterize(self) -> None:
        """
        Merge all branches into a single convolutional layer for inference.
        """
        if self.infer:
            return  # Already in inference mode

        # Merge weights and biases from all branches
        merged_weight, merged_bias = self._merge_branches()

        # Create a new convolutional layer with merged parameters
        self.conv = nn.Conv2d(
            self.in_channels,
            self.out_channels,
            self.kernel_size,
            self.stride,
            self.padding,
            self.dilation,
            self.groups,
            bias=True,
        )
        self.conv.weight.data = merged_weight
        self.conv.bias.data = merged_bias

        # Detach parameters and delete branch modules
        for param in self.parameters():
            param.detach_()
        del self.branches
        del self.scale_branch
        if self.skip_connection:
            del self.skip_connection

        self.infer = True  # Switch to inference mode

    def _merge_branches(self) -> Tuple[torch.Tensor, torch.Tensor]:
        """
        Fuse all convolutional branches into single weight and bias tensors.
        """
        merged_weight = (
            torch.zeros_like(self.branches[0].conv.weight) if self.branches else 0
        )
        merged_bias = (
            torch.zeros(self.out_channels, device=self.branches[0].conv.weight.device)
            if self.branches
            else 0
        )

        # Merge scale branch if it exists
        if self.scale_branch:
            scale_weight, scale_bias = self._fuse_layer(self.scale_branch)
            scale_weight = F.pad(scale_weight, [self.kernel_size // 2] * 4)
            merged_weight += scale_weight
            merged_bias += scale_bias

        # Merge skip connection if it exists
        if self.skip_connection:
            skip_weight, skip_bias = self._fuse_layer(self.skip_connection)
            merged_weight += skip_weight
            merged_bias += skip_bias

        # Merge all convolutional branches
        for branch in self.branches:
            branch_weight, branch_bias = self._fuse_layer(branch)
            merged_weight += branch_weight
            merged_bias += branch_bias

        return merged_weight, merged_bias

    def _fuse_layer(
        self, layer: Union[nn.Sequential, nn.BatchNorm2d]
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """
        Fuse convolution and batch normalization layers into single weight and bias tensors.
        """
        if isinstance(layer, nn.Sequential):
            # Access named layers
            conv: nn.Conv2d = layer.conv  # Access by name
            bn: nn.BatchNorm2d = layer.bn  # Access by name
            weight = conv.weight
            bias = (
                conv.bias
                if conv.bias is not None
                else torch.zeros(conv.out_channels, device=weight.device)
            )
            gamma, beta, mean, var, eps = (
                bn.weight,
                bn.bias,
                bn.running_mean,
                bn.running_var,
                bn.eps,
            )
        else:
            # If the layer is only a batch normalization (identity), create identity weights
            assert isinstance(
                layer, nn.BatchNorm2d
            ), "Layer must be either Sequential or BatchNorm2d"
            if not hasattr(self, "identity_weight"):
                identity_weight = torch.zeros(
                    self.in_channels,
                    self.in_channels // self.groups,
                    self.kernel_size,
                    self.kernel_size,
                    device=layer.weight.device,
                )
                for i in range(self.in_channels):
                    identity_weight[
                        i,
                        i % (self.in_channels // self.groups),
                        self.kernel_size // 2,
                        self.kernel_size // 2,
                    ] = 1
                self.identity_weight = identity_weight
            weight = self.identity_weight
            bias = layer.bias
            gamma, beta, mean, var, eps = (
                layer.weight,
                layer.bias,
                layer.running_mean,
                layer.running_var,
                layer.eps,
            )

        # Calculate standard deviation
        std = torch.sqrt(var + eps)
        # Scale weights
        fused_weight = weight * (gamma / std).reshape(-1, 1, 1, 1)
        # Scale and shift biases
        fused_bias = (bias - mean) * (gamma / std) + beta
        return fused_weight, fused_bias

    def _conv_bn(self, kernel_size: int, padding: int) -> nn.Sequential:
        """
        Helper method to create a convolutional layer followed by batch normalization.
        Layers are named 'conv' and 'bn' for easy access during fusion.
        """
        return nn.Sequential(
            OrderedDict(
                [
                    (
                        "conv",
                        nn.Conv2d(
                            self.in_channels,
                            self.out_channels,
                            kernel_size,
                            stride=self.stride,
                            padding=padding,
                            dilation=self.dilation,
                            groups=self.groups,
                            bias=False,
                        ),
                    ),
                    ("bn", nn.BatchNorm2d(self.out_channels)),
                ]
            )
        )


# ---------------------------
# Model Transformation Function
# ---------------------------
def transform_model(model: nn.Module) -> nn.Module:
    """
    Transforms the model by reparameterizing all layers that support it.
    This is typically used to merge multiple branches into single layers for inference.
    """
    model_copy = copy.deepcopy(
        model
    )  # Create a deep copy to avoid modifying the original model
    for layer in model_copy.modules():
        if hasattr(layer, "reparameterize"):
            layer.reparameterize()  # Merge branches if possible
    return model_copy


# ---------------------------
# Self-Attention Module
# ---------------------------
class SelfAttention(nn.Module):
    """
    Self-Attention mechanism that computes attention over spatial dimensions.
    """

    def __init__(
        self,
        embed_dim: int,
        head_dim: int = 32,
        bias: bool = False,
        attn_drop: float = 0.0,
        proj_drop: float = 0.0,
    ) -> None:
        super().__init__()
        assert (
            embed_dim % head_dim == 0
        ), "Embedding dimension must be divisible by head dimension"
        self.head_dim = head_dim
        self.num_heads = embed_dim // head_dim
        self.scale = head_dim**-0.5  # Scaling factor for attention scores

        # Linear layers for query, key, and value
        self.qkv = nn.Linear(embed_dim, embed_dim * 3, bias=bias)
        self.attn_dropout = nn.Dropout(attn_drop)  # Dropout for attention scores
        self.proj = nn.Linear(embed_dim, embed_dim)  # Output projection
        self.proj_dropout = nn.Dropout(proj_drop)  # Dropout after projection

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        batch_size, channels, height, width = x.shape
        num_tokens = height * width

        if x.dim() == 4:
            # Flatten spatial dimensions and transpose for attention computation
            x = x.flatten(2).transpose(
                1, 2
            )  # Shape: (batch_size, num_tokens, channels)

        # Compute query, key, and value
        qkv = self.qkv(x).reshape(
            batch_size, num_tokens, 3, self.num_heads, self.head_dim
        )
        qkv = qkv.permute(
            2, 0, 3, 1, 4
        )  # Shape: (3, batch_size, num_heads, num_tokens, head_dim)
        q, k, v = qkv.unbind(0)  # Separate Q, K, V

        # Compute scaled dot-product attention
        attn_scores = (q * self.scale) @ k.transpose(
            -2, -1
        )  # Shape: (batch_size, num_heads, num_tokens, num_tokens)
        attn_probs = attn_scores.softmax(
            dim=-1
        )  # Apply softmax to get attention probabilities
        attn_probs = self.attn_dropout(
            attn_probs
        )  # Apply dropout to attention probabilities

        # Compute attention output
        attn_output = (
            attn_probs @ v
        )  # Shape: (batch_size, num_heads, num_tokens, head_dim)
        attn_output = attn_output.transpose(1, 2).reshape(
            batch_size, num_tokens, channels
        )  # Reshape

        # Apply output projection and dropout
        attn_output = self.proj(attn_output)
        attn_output = self.proj_dropout(attn_output)

        if x.dim() == 3:
            # Reshape back to spatial dimensions if necessary
            attn_output = attn_output.transpose(1, 2).reshape(
                batch_size, channels, height, width
            )

        return attn_output


# ---------------------------
# Mixer Module
# ---------------------------
class Mixer(nn.Module):
    """
    Mixer module that performs channel mixing using a flexible block.
    It can be reparameterized for efficient inference.
    """

    def __init__(
        self,
        embed_dim: int,
        kernel_size: int = 3,
    ):
        super().__init__()
        self.embed_dim = embed_dim
        self.kernel_size = kernel_size
        self.inference = False

        # Normalization branch
        self.norm_block = FlexibleBlock(
            in_channels=embed_dim,
            out_channels=embed_dim,
            kernel_size=kernel_size,
            padding=kernel_size // 2,
            groups=embed_dim,
            use_activation=False,
            use_scale=False,
            num_branches=0,
        )

        # Mixer branch
        self.mixer_block = FlexibleBlock(
            in_channels=embed_dim,
            out_channels=embed_dim,
            kernel_size=kernel_size,
            padding=kernel_size // 2,
            groups=embed_dim,
            use_activation=False,
        )

        # Learnable scaling parameter
        self.scale = nn.Parameter(
            1e-5 * torch.ones(embed_dim, 1, 1), requires_grad=True
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if hasattr(self, "conv"):
            # If reparameterized, use the single convolution
            return self.conv(x)

        # Compute mixer and normalization outputs
        mixer_out = self.mixer_block(x)
        norm_out = self.norm_block(x)
        # Apply scaling and residual connection
        return x + self.scale * (mixer_out - norm_out)

    def reparameterize(self) -> None:
        """
        Merge mixer and normalization branches into a single convolutional layer for inference.
        """
        if self.inference:
            return  # Already reparameterized

        # Reparameterize both mixer and normalization blocks
        self.mixer_block.reparameterize()
        self.norm_block.reparameterize()

        # Merge weights and biases from mixer and normalization
        merged_weight = self.mixer_block.conv.weight + self.scale.unsqueeze(-1) * (
            self.mixer_block.conv.weight - self.norm_block.conv.weight
        )
        merged_bias = self.scale.squeeze() * (
            self.mixer_block.conv.bias - self.norm_block.conv.bias
        )

        # Create a new convolutional layer with merged parameters
        self.conv = nn.Conv2d(
            self.embed_dim,
            self.embed_dim,
            self.kernel_size,
            stride=1,
            padding=self.kernel_size // 2,
            groups=self.embed_dim,
            bias=True,
        )
        self.conv.weight.data = merged_weight
        self.conv.bias.data = merged_bias

        # Detach parameters and delete branches
        for param in self.parameters():
            param.detach_()
        del self.mixer_block
        del self.norm_block
        del self.scale

        self.inference = True  # Switch to inference mode


# ---------------------------
# Feed-Forward Network
# ---------------------------
class FeedForward(nn.Module):
    """
    Feed-Forward Network consisting of depthwise convolution, activation, and pointwise convolutions with dropout.
    """

    def __init__(
        self,
        in_channels: int,
        hidden_channels: Optional[int] = None,
        out_channels: Optional[int] = None,
        activation: nn.Module = nn.GELU,
        dropout_rate: float = 0.0,
    ) -> None:
        super().__init__()
        out_channels = (
            out_channels or in_channels
        )  # Default to in_channels if out_channels not provided
        hidden_channels = (
            hidden_channels or in_channels
        )  # Default to in_channels if hidden_channels not provided

        # Depthwise convolution followed by batch normalization
        self.conv = nn.Sequential(
            OrderedDict(
                [
                    (
                        "conv",
                        nn.Conv2d(
                            in_channels,
                            out_channels,
                            kernel_size=7,
                            padding=3,
                            groups=in_channels,
                            bias=False,
                        ),
                    ),
                    ("bn", nn.BatchNorm2d(out_channels)),
                ]
            )
        )

        # Pointwise convolution layers for the MLP
        self.fc1 = nn.Conv2d(in_channels, hidden_channels, kernel_size=1)
        self.activation = activation()
        self.fc2 = nn.Conv2d(hidden_channels, out_channels, kernel_size=1)
        self.dropout = nn.Dropout(dropout_rate)

        # Initialize weights
        self.apply(self._init_weights)

    def _init_weights(self, module: nn.Module) -> None:
        """
        Initialize weights using truncated normal distribution and biases to zero.
        """
        if isinstance(module, nn.Conv2d):
            trunc_normal_(module.weight, std=0.02)
            if module.bias is not None:
                nn.init.constant_(module.bias, 0)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.conv(x)  # Apply depthwise convolution and batch norm
        x = self.fc1(x)  # First pointwise convolution
        x = self.activation(x)  # Apply activation function
        x = self.dropout(x)  # Apply dropout
        x = self.fc2(x)  # Second pointwise convolution
        x = self.dropout(x)  # Apply dropout
        return x


# ---------------------------
# Positional Encoding Module
# ---------------------------
class PositionalEncoding(nn.Module):
    """
    Positional Encoding module that adds positional information to the input tensor.
    It can be reparameterized for efficient inference.
    """

    def __init__(
        self,
        in_channels: int,
        embed_dim: int = 768,
        spatial_shape: Union[int, Tuple[int, int]] = (3, 3),
        inference: bool = False,
    ) -> None:
        super().__init__()
        if isinstance(spatial_shape, int):
            spatial_shape = (spatial_shape, spatial_shape)
        assert (
            isinstance(spatial_shape, tuple) and len(spatial_shape) == 2
        ), "spatial_shape must be a tuple of two integers"

        self.spatial_shape = spatial_shape
        self.embed_dim = embed_dim
        self.in_channels = in_channels
        self.groups = embed_dim
        self.inference = inference

        if self.inference:
            # Single convolutional layer for inference
            self.conv = nn.Conv2d(
                in_channels,
                embed_dim,
                kernel_size=self.spatial_shape,
                stride=1,
                padding=self.spatial_shape[0] // 2,
                groups=self.embed_dim,
                bias=True,
            )
        else:
            # Positional encoding convolution
            self.pe = nn.Conv2d(
                in_channels,
                embed_dim,
                kernel_size=self.spatial_shape,
                stride=1,
                padding=self.spatial_shape[0] // 2,
                groups=self.embed_dim,
                bias=True,
            )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if hasattr(self, "conv"):
            # Inference mode: apply single convolution
            return self.conv(x)
        # Add positional encoding to the input
        return self.pe(x) + x

    def reparameterize(self) -> None:
        """
        Merge positional encoding with input using a single convolutional layer for inference.
        """
        if self.inference:
            return  # Already in inference mode

        # Calculate the number of input channels per group
        input_dim_per_group = self.in_channels // self.groups

        # Create an identity convolution to preserve the original input
        identity = torch.zeros(
            self.in_channels,
            input_dim_per_group,
            *self.spatial_shape,
            dtype=self.pe.weight.dtype,
            device=self.pe.weight.device,
        )
        for i in range(self.in_channels):
            identity[
                i,
                i % input_dim_per_group,
                self.spatial_shape[0] // 2,
                self.spatial_shape[1] // 2,
            ] = 1

        # Fuse the identity convolution with positional encoding weights
        fused_weight = identity + self.pe.weight
        fused_bias = self.pe.bias

        # Create a new convolutional layer with fused weights and biases
        self.conv = nn.Conv2d(
            self.in_channels,
            self.embed_dim,
            kernel_size=self.spatial_shape,
            stride=1,
            padding=self.spatial_shape[0] // 2,
            groups=self.embed_dim,
            bias=True,
        )
        self.conv.weight.data = fused_weight
        self.conv.bias.data = fused_bias

        # Detach parameters and delete positional encoding module
        for param in self.parameters():
            param.detach_()
        del self.pe


# ---------------------------
# Mixer Block
# ---------------------------
class MixerBlock(nn.Module):
    """
    Mixer block that combines mixer operations with a feed-forward network and stochastic depth.
    """

    def __init__(
        self,
        embed_dim: int,
        mlp_ratio: float = 4.0,
        drop_path_rate: float = 0.0,
    ):
        super().__init__()
        self.mixer = Mixer(embed_dim)  # Mixer module
        hidden_dim = int(embed_dim * mlp_ratio)  # Calculate hidden dimension for FFN
        self.feed_forward = FeedForward(embed_dim, hidden_dim)  # Feed-Forward Network
        self.drop_path = (
            DropPath(drop_path_rate) if drop_path_rate > 0.0 else nn.Identity()
        )  # Stochastic depth
        self.scale = nn.Parameter(
            1e-5 * torch.ones(embed_dim, 1, 1), requires_grad=True
        )  # Learnable scaling

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.mixer(x)  # Apply mixer
        # Apply feed-forward network with scaling and stochastic depth
        x = x + self.drop_path(self.scale * self.feed_forward(x))
        return x


# ---------------------------
# Attention Block
# ---------------------------
class AttentionBlock(nn.Module):
    """
    Attention block that integrates self-attention with a feed-forward network and normalization.
    """

    def __init__(
        self,
        embed_dim: int,
        mlp_ratio: float = 4.0,
        norm_layer: nn.Module = nn.BatchNorm2d,
        drop_path_rate: float = 0.0,
    ):
        super().__init__()
        self.norm = norm_layer(embed_dim)  # Normalization layer
        self.attention = SelfAttention(embed_dim)  # Self-Attention module
        hidden_dim = int(embed_dim * mlp_ratio)  # Calculate hidden dimension for FFN
        self.feed_forward = FeedForward(embed_dim, hidden_dim)  # Feed-Forward Network
        self.drop_path = (
            DropPath(drop_path_rate) if drop_path_rate > 0.0 else nn.Identity()
        )  # Stochastic depth
        # Learnable scaling parameters for attention and FFN
        self.scale1 = nn.Parameter(
            1e-5 * torch.ones(embed_dim, 1, 1), requires_grad=True
        )
        self.scale2 = nn.Parameter(
            1e-5 * torch.ones(embed_dim, 1, 1), requires_grad=True
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # Apply self-attention with scaling and stochastic depth
        attn_out = self.attention(self.norm(x))
        x = x + self.drop_path(self.scale1 * attn_out)
        # Apply feed-forward network with scaling and stochastic depth
        ffn_out = self.feed_forward(x)
        x = x + self.drop_path(self.scale2 * ffn_out)
        return x


# ---------------------------
# Block Creation Function
# ---------------------------
def create_blocks(
    embed_dim: int,
    stage_idx: int,
    num_blocks: List[int],
    mixer_type: str,
    mlp_ratio: float = 4.0,
    norm_layer: nn.Module = nn.BatchNorm2d,
    drop_path_rate: float = 0.0,
) -> nn.Sequential:
    """
    Create a sequence of Mixer or Attention blocks for a given stage.
    """
    blocks = []
    total_blocks = sum(
        num_blocks[:stage_idx]
    )  # Calculate total blocks before current stage
    total_blocks_all = sum(num_blocks)  # Total number of blocks in all stages

    for block_idx in range(num_blocks[stage_idx]):
        # Calculate drop path rate for stochastic depth
        dpr = drop_path_rate * (block_idx + total_blocks) / (total_blocks_all - 1)
        if mixer_type.lower() == "mixer":
            # Append MixerBlock
            blocks.append(
                MixerBlock(
                    embed_dim,
                    mlp_ratio=mlp_ratio,
                    drop_path_rate=dpr,
                )
            )
        elif mixer_type.lower() == "attention":
            # Append AttentionBlock
            blocks.append(
                AttentionBlock(
                    embed_dim,
                    mlp_ratio=mlp_ratio,
                    norm_layer=norm_layer,
                    drop_path_rate=dpr,
                )
            )
        else:
            raise ValueError(f"Unsupported mixer type: {mixer_type}")
    return nn.Sequential(*blocks)


# ---------------------------
# FastViT Model
# ---------------------------
class FastViTModel(nn.Module):
    """
    FastViT model integrating multiple stages with Mixer or Attention blocks and positional encodings.
    Supports model reparameterization for efficient inference.
    """

    def __init__(
        self,
        layers: List[int],
        mixers: Tuple[str, ...],
        embed_dims: Optional[List[int]] = None,
        mlp_ratios: Optional[List[float]] = None,
        pos_embs: Optional[List[Optional[nn.Module]]] = None,
        drop_path_rate: float = 0.1,
    ) -> None:
        super().__init__()
        num_stages = len(layers)
        embed_dims = embed_dims or [768] * num_stages  # Default embedding dimensions
        mlp_ratios = mlp_ratios or [4.0] * num_stages  # Default MLP ratios
        pos_embs = pos_embs or [None] * num_stages  # Default positional encodings

        network_layers = []
        self.transitions = nn.ModuleList()  # To hold transition layers between stages

        for stage_idx in range(num_stages):
            # Add positional encoding if provided
            if pos_embs[stage_idx]:
                network_layers.append(
                    pos_embs[stage_idx](
                        embed_dims[stage_idx], embed_dims[stage_idx], inference=False
                    )
                )
            # Create and add blocks for the current stage
            stage_blocks = create_blocks(
                embed_dim=embed_dims[stage_idx],
                stage_idx=stage_idx,
                num_blocks=layers,
                mixer_type=mixers[stage_idx],
                mlp_ratio=mlp_ratios[stage_idx],
                drop_path_rate=drop_path_rate,
            )
            network_layers.append(stage_blocks)

            # Add a transition layer if not the last stage and embed_dims change
            if stage_idx < num_stages - 1:
                if embed_dims[stage_idx] != embed_dims[stage_idx + 1]:
                    transition = nn.Sequential(
                        OrderedDict(
                            [
                                (
                                    "conv",
                                    nn.Conv2d(
                                        embed_dims[stage_idx],
                                        embed_dims[stage_idx + 1],
                                        kernel_size=1,
                                        stride=1,
                                        bias=False,
                                    ),
                                ),
                                ("bn", nn.BatchNorm2d(embed_dims[stage_idx + 1])),
                                ("relu", nn.ReLU(inplace=True)),
                            ]
                        )
                    )
                    self.transitions.append(transition)
                else:
                    # If embedding dimensions are the same, append an identity layer
                    self.transitions.append(nn.Identity())

        self.network = nn.ModuleList(network_layers)  # Store all network layers
        self.transitions = nn.ModuleList(
            self.transitions
        )  # Store all transition layers
        self.apply(self._init_weights)  # Initialize weights

    def _init_weights(self, module: nn.Module) -> None:
        """
        Initialize weights for linear layers using truncated normal distribution.
        """
        if isinstance(module, nn.Linear):
            trunc_normal_(module.weight, std=0.02)
            if module.bias is not None:
                nn.init.constant_(module.bias, 0)

    @staticmethod
    def scrub_checkpoint(checkpoint: dict, model: nn.Module) -> dict:
        """
        Clean a checkpoint by retaining only matching keys with the model's state dictionary.
        """
        cleaned_checkpoint = {}
        model_state = model.state_dict()
        for key, value in checkpoint.items():
            if key in model_state and value.shape == model_state[key].shape:
                cleaned_checkpoint[key] = value
        return cleaned_checkpoint

    def forward_tokens(self, x: torch.Tensor) -> torch.Tensor:
        """
        Forward pass through all network layers (tokens).
        """
        for stage_idx, layer in enumerate(self.network):
            x = layer(x)
            if stage_idx < len(self.transitions):
                x = self.transitions[stage_idx](x)  # Apply transition layer
        return x

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """
        Forward pass through the model.
        """
        return self.forward_tokens(x)
