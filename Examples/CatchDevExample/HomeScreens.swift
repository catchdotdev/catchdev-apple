import UIKit

final class HomeViewController: DemoViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        setContent([
            makeLabel("Home"),
            makeButton(title: "Open Product Detail", identifier: "example.home.detail") { [weak self] in
                self?.push(ProductDetailViewController())
            },
        ])
    }
}

final class ProductDetailViewController: DemoViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Product Detail"
        setContent([
            makeLabel("Product Detail"),
            makeButton(title: "See Reviews", identifier: "example.detail.reviews") { [weak self] in
                self?.push(ReviewsViewController())
            },
        ])
    }
}

final class ReviewsViewController: DemoViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reviews"
        setContent([makeLabel("Reviews")])
    }
}
