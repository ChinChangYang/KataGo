//
//  NeuralNetworkModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/24.
//

import Foundation

struct NeuralNetworkModel: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let description: String
    let url: String
    let fileName: String
    let fileSize: Int
    let builtIn: Bool
    let nnLen: Int
    let humanUrl: String

    var downloadedURL: URL? {
        return URL.documentsDirectory.appendingPathComponent(fileName)
    }

    var visible: Bool {
        true
    }

    /// Initialize the neural network model
    /// - Parameters:
    ///   - title: the title of the model
    ///   - description: the description of the model
    ///   - url: the URL of the model
    ///   - humanUrl: the URL of the human SL model   s
    ///   - fileName: the file name of the model
    ///   - fileSize: the file size of the model
    ///   - builtIn: a flag to indicate that the model is built-in or not
    ///   - nnLen: neural network board length, default value should be equal to `COMPILE_MAX_BOARD_LEN`
    init(title: String,
         description: String,
         url: String,
         humanUrl: String = "",
         fileName: String,
         fileSize: Int,
         builtIn: Bool = false,
         nnLen: Int = 37) {

        self.title = title
        self.description = description
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        self.builtIn = builtIn
        self.nnLen = nnLen
        self.humanUrl = humanUrl
    }

    static let allCases: [NeuralNetworkModel] = [
        .init(
            title: "Built-in KataGo Core ML model",
            description: """
This model is based on the strongest network from KataGo's distributed training and has been converted to Core ML with 16-bit operations. It's optimized to run efficiently on Apple devices using the Neural Engine for board sizes up to 19x19.

Name: kata1-b28c512nbt-adam-s11165M-d5387M.
Uploaded at: 2025-10-02 01:23:42 UTC.
Elo Rating: 14082.9 ± 9.7 - (6812 games).

Board sizes: 2x2 to 19x19.
""",
            url: Bundle.main.path(forResource: "KataGoModel19x19fp16", ofType: "mlpackage") ?? "",
            humanUrl: Bundle.main.path(forResource: "KataGoModel19x19fp16m1", ofType: "mlpackage") ?? "",
            fileName: "builtin.bin.gz",
            fileSize: 271_357_345,
            builtIn: true,
            nnLen: 19
        ),
        .init(
            title: "Official KataGo Network",
            description: """
This is the strongest confidently-rated network in KataGo distributed training. It runs using the GPU and may offer faster performance than the Core ML model on high-end Macs.

This app will irregularly update the URL for the strongest confidently-rated network. If a new network becomes available, you can keep using your current one or manually switch by deleting it and downloading the latest version.

Name: kata1-b28c512nbt-adam-s11165M-d5387M.
Uploaded at: 2025-10-02 01:23:42 UTC.
Elo Rating: 14082.9 ± 9.7 - (6812 games).

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b28c512nbt-adam-s11165M-d5387M.bin.gz",
            fileName: "official.bin.gz",
            fileSize: 271_357_345
        ),
        .init(
            title: "FD3 Network",
            description: """
This is a network privately finetuned and used by a number of competitive KataGo users originally in 2024 with learning rate drops to much lower than the higher learning rate maintained by the official KataGo nets, and which has since been released for public download. This network is probably similar in strength or slightly stronger than the official networks in normal games as of April 2025! Although it might not stay as up to date on certain blind spot or particular misevaluation fixes as various such training continues ongoingly through 2025.

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models_extra/fd3.bin.gz",
            fileName: "fd3.bin.gz",
            fileSize: 271_357_345
        ),
        .init(
            title: "Lionffen b6c64 Network",
            description: """
Trained by "lionffen", this is a heavily optimized very small 6-block network that in normal games may be competitive with or stronger than many of KataGo's historical 10-block nets on equal visits, while running much faster due to its tiny size! It has been trained specifically for 19x19 and might NOT perform well on any other board sizes. Additionally, due to being a very shallow net (only 6 residual blocks), it will have too few layers to be capable of "perceiving" the the whole board at once, so like any small net, it may be uncharacteristically weak relative to its strength otherwise in situations involving very large dragons or capturing races, more than neural nets in Go already are in such cases.

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models_extra/lionffen_b6c64_3x3_v10.txt.gz",
            fileName: "lionffen.txt.gz",
            fileSize: 2_196_103
        ),
        .init(
            title: "Lionffen b24c64 Network",
            description: """
Trained by "lionffen", this is a heavily optimized small network with a number of parameters between KataGo's historical 6 and 10 block networks in normal games that may be competitive with KataGo's historical 15-block nets or weaker 20-block networks. However, it might not be suitable for general game review/analysis, even on weaker hardware that might benefit from a small/fast net, since it appears to have been optimized head-to-head strength against superhuman opponents and might be fragile and play poor moves when behind or in some unfamiliar situations.

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models_extra/lionffen_b24c64_3x3_v3_12300.bin.gz",
            fileName: "lionffen_b24c64_3x3_v3_12300.bin.gz",
            fileSize: 4_842_138
        ),
        .init(
            title: "Finetuned 9x9 Network",
            description: """
This net is likely one of the strongest KataGo nets for 9x9, even compared to nets more recent than it! It was specially finetuned for a few months on a couple of GPUs exclusively on a diverse set of 9x9 board positions, including large trees of positions that KataGo's main nets had significant misevaluations on. This was also the net used to generate the 9x9 book at https://katagobooks.org/.

Do not expect this net to be any good for sizes other than 9x9. Due to the 9x9-exclusive finetuning, it will have forgotten how to evaluate other sizes accurately.

If you're interested, see the original github release post of this net for more training details!

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models_extra/kata9x9-b18c384nbt-20231025.bin.gz",
            fileName: "kata9x9.bin.gz",
            fileSize: 97_878_277
        ),
        .init(
            title: "Short Distributed Test Run Rect15 Final Net",
            description: """
Just for fun, this is the final net of a short test run for KataGo's distributed training infrastructure, before the official run launched. It was trained on a wide variety of rectangular board sizes up to 15x15, including a lot of heavily non-square sizes, such as 6x15. It is only a 20 block net, and was trained for far less time than KataGo's main nets. It has never seen a 19x19 board, and will be weak on 19x19 by bot standards, but may still be very strong by human amateur standards and still play reasonably by sheer extrapolation.

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models_extra/rect15-b20c256-s343365760-d96847752.bin.gz",
            fileName: "rect15.bin.gz",
            fileSize: 87_321_509
        ),
        .init(
            title: "Strong Large Board Net M2",
            description: """
This is a strong net finetuned by "Friday9i" for months starting from KataGo's official nets to be vastly stronger on boards larger than 19x19! It should be stronger than the official nets by many hundreds of Elo for board lengths in the high 20s, and virtually always winning on board lengths in the 30s, where the official nets start to behave nonsensically. As of mid 2025, this net is the ideal net to use for large board play for the "+bs50" executables offered at KataGo's latest release page that support sizes up to 50x50.

According to Friday9i, even this net might not be 100% reliable on score maximization or finishing up dame or other small details for board lengths in the high 30s or in the 40s but should still behave overall reasonably and play fine. See this forum post for more stats and details. Enjoy!

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models_extra/M2-s40190750-d164645490.bin.gz",
            fileName: "m2.bin.gz",
            fileSize: 271_357_345
        ),
        .init(
            title: "Strong Igo Hatsuyoron 120 Net",
            description: """
Trained by "Friday9i" for close to a year, this is one of the strongest publicly-available networks specially trained to understand what has been termed the most difficult problem in the world, problem number 120 in a classic problem collection from Inoue Dosetsu Inseki dating back to the 1700s.

This network, its earlier versions, and/or some further never-publicly-released networks along with extensive human work and analysis by Thomas Redecker and other researchers are responsible for the significant discoveries and refinements in human understanding of the problem in the years after initial new moves were discovered by KataGo in 2019. The effort to analyze and solve this problem has been an amazing effort across the years, and is documented in detail by Thomas Redecker at https://igohatsuyoron120.de/.

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models_extra/igoh120latest-40b.bin.gz",
            fileName: "igoh120latest.bin.gz",
            fileSize: 173_502_836
        )
    ]
}
