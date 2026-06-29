import UIKit

final class ExploreViewController: DemoViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Explore"
        setContent([
            makeLabel("Explore"),
            makeButton(title: "Open Category", identifier: "example.explore.category") { [weak self] in
                self?.push(CategoryViewController())
            },
        ])
    }
}

final class CategoryViewController: DemoViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Category"
        setContent([makeLabel("Category")])
    }
}
