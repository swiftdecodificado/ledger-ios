import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let dependencies = AppDependencies.make()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = LabViewController(
            paymentViewController: PaymentViewController(paymentClient: dependencies.paymentClient),
            mockServer: dependencies.mockServer
        )
        window.makeKeyAndVisible()
        self.window = window
    }
}
