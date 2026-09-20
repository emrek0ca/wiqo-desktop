import XCTest

final class CanvasPackageDetectorTests: XCTestCase {
    func testDetectsKnownPackagesUnderTheirPipNames() {
        let code = """
        import numpy as np
        import pandas as pd
        from sklearn.model_selection import train_test_split
        import cv2
        from PIL import Image
        """
        XCTAssertEqual(
            CanvasPackageDetector.detect(in: code),
            ["numpy", "pandas", "scikit-learn", "opencv-python-headless", "pillow"]
        )
    }

    func testIgnoresStandardLibraryRelativeAndUnknownModules() {
        let code = """
        import os, sys, json
        from collections import Counter
        from . import helpers
        from .utils import thing
        import my_private_module
        """
        XCTAssertEqual(CanvasPackageDetector.detect(in: code), [])
    }

    func testHandlesIndentationCommaListsAndDuplicates() {
        let code = """
        def main():
            import numpy as np, pandas as pd
            import numpy
        """
        XCTAssertEqual(CanvasPackageDetector.detect(in: code), ["numpy", "pandas"])
    }

    func testNeverReturnsMoreThanTheBackendAccepts() {
        let names = ["numpy", "pandas", "matplotlib", "scipy", "seaborn", "plotly", "sympy", "networkx", "statsmodels", "openpyxl"]
        let code = names.map { "import \($0)" }.joined(separator: "\n")
        XCTAssertEqual(CanvasPackageDetector.detect(in: code).count, CanvasPackageDetector.limit)
    }

    func testRecognisesProgramsThatOpenANativeWindow() {
        XCTAssertTrue(CanvasPackageDetector.opensNativeWindow("import tkinter as tk\nroot = tk.Tk()"))
        XCTAssertTrue(CanvasPackageDetector.opensNativeWindow("from PyQt5.QtWidgets import QApplication"))
        XCTAssertFalse(CanvasPackageDetector.opensNativeWindow("import numpy as np\nprint(np.arange(3))"))
    }
}
