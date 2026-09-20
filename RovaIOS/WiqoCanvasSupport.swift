import Foundation

/// Finds the third-party libraries a Python program imports, so the canvas can prepare them
/// without the user having to know pip names.
///
/// Only well-known packages are recognised. An unfamiliar `import utils` is more likely the user's
/// own module than a public package, and installing a stranger's package under that name would be
/// worse than asking - so anything not on this list is left for the user to add by hand.
enum CanvasPackageDetector {
    /// import name -> pip package name
    private static let known: [String: String] = [
        "numpy": "numpy",
        "pandas": "pandas",
        "matplotlib": "matplotlib",
        "scipy": "scipy",
        "seaborn": "seaborn",
        "plotly": "plotly",
        "sympy": "sympy",
        "networkx": "networkx",
        "statsmodels": "statsmodels",
        "sklearn": "scikit-learn",
        "cv2": "opencv-python-headless",
        "PIL": "pillow",
        "bs4": "beautifulsoup4",
        "lxml": "lxml",
        "yaml": "pyyaml",
        "jinja2": "jinja2",
        "markdown": "markdown",
        "pydantic": "pydantic",
        "tqdm": "tqdm",
        "rich": "rich",
        "tabulate": "tabulate",
        "dateutil": "python-dateutil",
        "pytz": "pytz",
        "openpyxl": "openpyxl",
        "xlsxwriter": "xlsxwriter",
        "reportlab": "reportlab",
        "fpdf": "fpdf2",
        "docx": "python-docx",
        "pptx": "python-pptx",
        "qrcode": "qrcode",
        "wordcloud": "wordcloud",
        "folium": "folium",
        "nltk": "nltk"
    ]

    /// The backend accepts at most this many packages per run.
    static let limit = 8

    static func detect(in code: String) -> [String] {
        var result: [String] = []
        for rawLine in code.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            var modules: [String] = []
            if line.hasPrefix("import ") {
                for part in line.dropFirst(7).split(separator: ",") {
                    if let name = part.trimmingCharacters(in: .whitespaces).split(separator: " ").first {
                        modules.append(String(name))
                    }
                }
            } else if line.hasPrefix("from ") {
                if let name = line.dropFirst(5).split(separator: " ").first, !name.hasPrefix(".") {
                    modules.append(String(name))
                }
            }
            for module in modules {
                guard let top = module.split(separator: ".").first,
                      let package = known[String(top)],
                      !result.contains(package) else { continue }
                result.append(package)
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// True when the program opens a native window (tkinter, pygame, Qt, ...). That kind of
    /// interface cannot be drawn on a phone, and the canvas says so instead of showing an empty
    /// result.
    static func opensNativeWindow(_ code: String) -> Bool {
        let markers = ["import tkinter", "from tkinter", "import pygame", "from PyQt", "import PyQt", "from PySide", "import turtle", "import kivy"]
        return markers.contains { code.contains($0) }
    }
}
